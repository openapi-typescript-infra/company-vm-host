import fs from "node:fs";
import { randomUUID } from "node:crypto";
export class HostClient {
  constructor(origin, token) {
    this.origin = new URL(origin);
    if (
      this.origin.protocol !== "https:" &&
      this.origin.hostname !== "127.0.0.1"
    )
      throw new Error("Use HTTPS or host-local loopback");
    this.token = token;
  }
  async call(method, path, input) {
    const r = await fetch(new URL("/v1/" + path, this.origin), {
      method,
      redirect: "error",
      headers: {
        authorization: `Bearer ${this.token}`,
        "content-type": "application/json",
      },
      body: input === undefined ? undefined : JSON.stringify(input),
      signal: AbortSignal.timeout(3660000),
    });
    const value = await r.json();
    if (!r.ok) throw new Error(value.error ?? `Host status ${r.status}`);
    return value;
  }
  async acquire(profile, kind = "agent", ttlSeconds = 600) {
    return this.call("POST", "leases", {
      requestId: `job-${randomUUID()}`,
      profile,
      kind,
      ttlSeconds,
    });
  }
  async wait(id) {
    for (;;) {
      const lease = await this.call("GET", `leases/${id}`);
      if (lease.status === "ready") return lease;
      if (!["queued", "starting"].includes(lease.status))
        throw new Error(`Lease ${lease.status}`);
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
}
// CLI is useful for CI wrappers; credentials are read from a file, never argv.
if (process.argv[1]?.endsWith("/client.mjs")) {
  const client = new HostClient(
    process.env.COMPANY_HOST_URL,
    fs.readFileSync(process.env.COMPANY_HOST_TOKEN_FILE, "utf8").trim(),
  );
  const [profile, recipe] = process.argv.slice(2);
  const lease = await client.acquire(profile, "ci", 7200);
  const renewal = setInterval(
    () => client.call("POST", `leases/${lease.id}/renew`, {}).catch(() => {}),
    60000,
  );
  try {
    await client.wait(lease.id);
    const result = await client.call("POST", `leases/${lease.id}/run`, {
      recipe,
    });
    console.log(JSON.stringify(result));
    process.exitCode = result.exitCode === 0 ? 0 : 1;
  } finally {
    clearInterval(renewal);
    await client.call("DELETE", `leases/${lease.id}`);
  }
}

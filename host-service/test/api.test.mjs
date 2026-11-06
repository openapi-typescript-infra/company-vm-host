import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Scheduler } from "../src/scheduler.mjs";
import { createServer } from "../src/server.mjs";
test("HTTP v1 rejects cross-company access and never exposes guest addresses", async () => {
  const c = JSON.parse(
    fs.readFileSync(new URL("../examples/host.example.json", import.meta.url)),
  );
  c.stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "host-api-"));
  const tokens = { "corporation-a": "a".repeat(40), "corporation-b": "b".repeat(40) };
  for (const [name, t] of Object.entries(c.companies)) {
    t.tokenFile = path.join(c.stateDir, name + ".token");
    fs.writeFileSync(t.tokenFile, tokens[name], { mode: 0o600 });
  }
  const scheduler = new Scheduler(c, {
    start: async () => ({ ip: "10.0.0.9" }),
    destroy: async () => {},
    run: async () => ({ exitCode: 0, output: "ok" }),
  });
  const server = createServer(c, scheduler);
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const url = `http://127.0.0.1:${server.address().port}`;
  const call = (company, method, route, input) =>
    fetch(url + route, {
      method,
      headers: {
        authorization: `Bearer ${tokens[company]}`,
        "content-type": "application/json",
      },
      body: input ? JSON.stringify(input) : undefined,
    });
  try {
    assert.equal((await fetch(url + "/v1/leases")).status, 401);
    const res = await call("corporation-a", "POST", "/v1/leases", {
      requestId: "one",
      profile: "ios",
      kind: "agent",
      ttlSeconds: 600,
    });
    assert.equal(res.status, 202);
    const lease = await res.json();
    await scheduler.tick();
    await new Promise((r) => setImmediate(r));
    const own = await (
      await call("corporation-a", "GET", `/v1/leases/${lease.id}`)
    ).json();
    assert.equal(own.runtime, undefined);
    assert.equal(own.status, "ready");
    for (const [method, suffix, input] of [
      ["GET", "", null],
      ["DELETE", "", null],
      ["POST", "/renew", {}],
      ["POST", "/run", { recipe: "simulators" }],
    ])
      assert.equal(
        (
          await call(
            "corporation-b",
            method,
            `/v1/leases/${lease.id}${suffix}`,
            input,
          )
        ).status,
        404,
      );
    assert.deepEqual(
      await (await call("corporation-b", "GET", "/v1/leases")).json(),
      [],
    );
    assert.equal(
      (
        await call("corporation-a", "POST", `/v1/leases/${lease.id}/run`, {
          recipe: "simulators",
          argv: ["rm"],
        })
      ).status,
      400,
    );
  } finally {
    await new Promise((r) => server.close(r));
    fs.rmSync(c.stateDir, { recursive: true, force: true });
  }
});

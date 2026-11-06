import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Scheduler } from "../src/scheduler.mjs";
import { validateConfig } from "../src/config.mjs";
const flush = () => new Promise((r) => setImmediate(r));
function setup() {
  const c = JSON.parse(
    fs.readFileSync(new URL("../examples/host.example.json", import.meta.url)),
  );
  c.stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "company-host-test-"));
  let now = Date.now();
  const calls = [];
  const driver = {
    start: async (l) => {
      calls.push(["start", l.company]);
      return { ip: "127.0.0.1" };
    },
    destroy: async (l) => {
      calls.push(["destroy", l.company]);
    },
    run: async () => ({ exitCode: 0, output: "ok" }),
  };
  const s = new Scheduler(validateConfig(c), driver, () => now);
  return {
    c,
    s,
    calls,
    driver,
    advance: (n) => (now += n),
    done: () => fs.rmSync(c.stateDir, { recursive: true, force: true }),
  };
}
const request = (id, kind = "agent") => ({
  requestId: id,
  profile: "ios",
  kind,
  ttlSeconds: 600,
});
test("company scoping, idempotency, quotas and CI share global slots", async () => {
  const x = setup();
  try {
    const a = await x.s.request("corporation-a", request("one"));
    const again = await x.s.request("corporation-a", request("one"));
    assert.equal(a.id, again.id);
    const a2 = await x.s.request("corporation-a", request("two", "ci"));
    const b = await x.s.request("corporation-b", request("other", "ci"));
    await x.s.tick();
    await flush();
    assert.equal(x.s.own("corporation-a", a.id).status, "ready");
    assert.equal(x.s.own("corporation-a", a2.id).status, "queued");
    assert.equal(x.s.own("corporation-b", b.id).status, "ready");
    assert.throws(() => x.s.own("corporation-b", a.id), /not found/);
    await assert.rejects(x.s.release("corporation-b", a.id), /not found/);
    await x.s.release("corporation-a", a.id);
    await flush();
    await x.s.tick();
    await flush();
    assert.equal(x.s.own("corporation-a", a2.id).status, "ready");
    await assert.rejects(
      x.s.run("corporation-a", a2.id, { recipe: "arbitrary-command" }),
      /Unknown recipe/,
    );
    assert.equal(
      (await x.s.run("corporation-a", a2.id, { recipe: "simulators" })).output,
      "ok",
    );
  } finally {
    x.done();
  }
});
test("expiry and restart recovery clean guests before reusing capacity", async () => {
  const x = setup();
  try {
    const a = await x.s.request("corporation-a", request("one"));
    await x.s.tick();
    await flush();
    x.advance(601000);
    await x.s.tick();
    await flush();
    assert.equal(x.s.own("corporation-a", a.id).status, "expired");
    const b = await x.s.request("corporation-b", request("two"));
    await x.s.tick();
    await flush();
    const restarted = new Scheduler(x.c, x.driver);
    await restarted.recover();
    assert.equal(restarted.own("corporation-b", b.id).status, "interrupted");
  } finally {
    x.done();
  }
});
test("failed cleanup holds capacity and retries instead of oversubscribing", async () => {
  const x = setup();
  try {
    x.c.capacity.macos = 1;
    const a = await x.s.request("corporation-a", request("one"));
    await x.s.request("corporation-b", request("two"));
    await x.s.tick();
    await flush();
    x.driver.destroy = async () => {
      throw new Error("busy");
    };
    await x.s.release("corporation-a", a.id);
    await flush();
    assert.equal(x.s.own("corporation-a", a.id).status, "cleanup-failed");
    await x.s.tick();
    assert.equal(x.calls.filter((c) => c[0] === "start").length, 1);
  } finally {
    x.done();
  }
});

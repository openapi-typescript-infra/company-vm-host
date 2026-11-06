import fs from "node:fs";
import path from "node:path";
import { loadConfig } from "./config.mjs";
import { TartDriver } from "./tart.mjs";
import { Scheduler } from "./scheduler.mjs";
import { createServer } from "./server.mjs";
if (process.platform !== "darwin")
  throw new Error("Host service requires macOS and Tart");
if (!fs.existsSync("/etc/company-vm-host/managed"))
  throw new Error(
    "Install the managed marker and guarded legacy scripts before starting the shared host",
  );
const c = loadConfig(process.argv[2] ?? "host.local.json");
fs.mkdirSync(c.stateDir, { recursive: true, mode: 0o700 });
const lock = path.join(c.stateDir, "service.pid");
if (fs.existsSync(lock)) {
  const pid = Number(fs.readFileSync(lock, "utf8"));
  if (!Number.isInteger(pid) || pid <= 0)
    throw new Error("Invalid service lock; inspect it before restarting");
  try {
    process.kill(pid, 0);
    throw new Error("Host service already running");
  } catch (e) {
    if (e.code !== "ESRCH") throw e;
  }
  fs.unlinkSync(lock);
}
fs.writeFileSync(lock, String(process.pid), { flag: "wx", mode: 0o600 });
const scheduler = new Scheduler(c, new TartDriver(c));
await scheduler.recover();
const server = createServer(c, scheduler);
const timer = setInterval(
  () => scheduler.tick().catch(() => console.error("Scheduler sweep failed")),
  1000,
);
server.listen(c.listen.port, c.listen.host, () =>
  console.log("Company VM host API v1 listening on loopback"),
);
async function shutdown() {
  clearInterval(timer);
  server.close();
  await Promise.all([...scheduler.tasks]);
  await scheduler.recover();
  fs.unlinkSync(lock);
  process.exit(0);
}
process.once("SIGTERM", shutdown);
process.once("SIGINT", shutdown);

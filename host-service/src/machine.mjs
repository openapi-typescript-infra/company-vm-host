// One independently supervised persistent Linux guest per company. This process
// shares no runtime code or release with the software installed inside the guest.
import fs from "node:fs";
import path from "node:path";
import { spawnSync, spawn } from "node:child_process";
import { check, name, fields } from "./config.mjs";
if (process.platform !== "darwin") throw new Error("Requires macOS");
const c = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
fields(c, [
  "company",
  "image",
  "tart",
  "tartHome",
  "cpus",
  "memoryMb",
  "brokerTunnel",
]);
check(
  name(c.company) &&
    typeof c.image === "string" &&
    !c.image.startsWith("-") &&
    path.isAbsolute(c.tart) &&
    path.isAbsolute(c.tartHome),
  "Invalid machine configuration",
);
check(
  Number.isInteger(c.cpus) &&
    c.cpus > 0 &&
    Number.isInteger(c.memoryMb) &&
    c.memoryMb >= 512,
  "Invalid machine resources",
);
fs.mkdirSync(c.tartHome, { recursive: true, mode: 0o700 });
const env = { ...process.env, TART_HOME: c.tartHome };
const vm = `company-${c.company}`;
function tart(args) {
  const r = spawnSync(c.tart, args, { env, encoding: "utf8" });
  if (r.status !== 0) throw new Error("Tart machine operation failed");
  return r.stdout;
}
const entries = JSON.parse(tart(["list", "--format", "json"]));
if (!entries.some((v) => v.Name === vm || v.name === vm))
  tart(["clone", c.image, vm]);
tart(["set", vm, "--cpu", String(c.cpus), "--memory", String(c.memoryMb)]);
if (c.brokerTunnel) {
  fields(c.brokerTunnel, ["sshUser", "sshKeyFile", "hostPort", "guestPort"]);
  check(
    /^[a-z_][a-z0-9_-]*$/.test(c.brokerTunnel.sshUser) &&
      path.isAbsolute(c.brokerTunnel.sshKeyFile ?? "") &&
      [c.brokerTunnel.hostPort, c.brokerTunnel.guestPort].every(
        (p) => Number.isInteger(p) && p > 1024 && p < 65536,
      ),
    "Invalid broker tunnel",
  );
}
let tunnel;
const timer = c.brokerTunnel
  ? setInterval(() => {
      if (tunnel) return;
      try {
        const ip = tart(["ip", vm]).trim();
        check(/^\d{1,3}(\.\d{1,3}){3}$/.test(ip), "Invalid guest address");
        const t = c.brokerTunnel;
        tunnel = spawn(
          "/usr/bin/ssh",
          [
            "-N",
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "ExitOnForwardFailure=yes",
            "-o",
            "ServerAliveInterval=15",
            "-o",
            "ServerAliveCountMax=2",
            "-o",
            "ConnectTimeout=5",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            `UserKnownHostsFile=${path.join(c.tartHome, "broker.known-hosts")}`,
            "-i",
            t.sshKeyFile,
            "-R",
            `127.0.0.1:${t.guestPort}:127.0.0.1:${t.hostPort}`,
            `${t.sshUser}@${ip}`,
          ],
          { stdio: "ignore" },
        );
        tunnel.once("exit", () => {
          tunnel = null;
        });
        tunnel.once("error", () => {
          tunnel = null;
        });
      } catch {}
    }, 5000)
  : null;
const child = spawn(
  c.tart,
  ["run", vm, "--no-graphics", "--no-audio", "--net-softnet"],
  { env, stdio: "inherit" },
);
for (const signal of ["SIGINT", "SIGTERM"])
  process.once(signal, () => {
    if (timer) clearInterval(timer);
    tunnel?.kill();
    spawnSync(c.tart, ["stop", vm], { env, stdio: "ignore" });
  });
child.once("exit", (code) => {
  if (timer) clearInterval(timer);
  tunnel?.kill();
  process.exitCode = code ?? 1;
});
child.once("error", () => {
  process.exitCode = 1;
});

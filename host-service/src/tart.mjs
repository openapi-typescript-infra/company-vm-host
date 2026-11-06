import fs from "node:fs";
import path from "node:path";
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { check } from "./config.mjs";
const exec = promisify(execFile);
const quote = (v) => "'" + v.replaceAll("'", "'\\''") + "'";
export class TartDriver {
  constructor(config) {
    this.config = config;
    this.children = new Map();
  }
  home(company) {
    return path.join(this.config.stateDir, "companies", company, "tart");
  }
  env(company) {
    return { ...process.env, TART_HOME: this.home(company) };
  }
  async cmd(company, args) {
    return exec(this.config.tart, args, {
      env: this.env(company),
      timeout: 120000,
      maxBuffer: 1024 * 1024,
    });
  }
  async start(lease, profile) {
    fs.mkdirSync(this.home(lease.company), { recursive: true, mode: 0o700 });
    await this.cmd(lease.company, ["clone", profile.image, lease.vm]);
    await this.cmd(lease.company, [
      "set",
      lease.vm,
      "--cpu",
      String(profile.cpus),
      "--memory",
      String(profile.memoryMb),
    ]);
    const log = fs.openSync(
      path.join(this.config.stateDir, lease.id + ".vm.log"),
      "a",
      0o600,
    );
    const child = spawn(
      this.config.tart,
      ["run", lease.vm, "--no-graphics", "--no-audio", "--net-softnet"],
      { env: this.env(lease.company), stdio: ["ignore", log, log] },
    );
    fs.closeSync(log);
    this.children.set(lease.id, child);
    let exited = false;
    child.once("exit", () => {
      exited = true;
    });
    child.once("error", () => {
      exited = true;
    });
    for (let i = 0; i < 120; i++) {
      if (exited) throw new Error("VM process exited during boot");
      try {
        const { stdout } = await this.cmd(lease.company, [
          "ip",
          lease.vm,
          "--resolver=agent",
        ]);
        const ip = stdout.trim();
        check(/^\d{1,3}(\.\d{1,3}){3}$/.test(ip), "Invalid VM address");
        await this.ssh(lease, profile, ip, ["/usr/bin/true"], 10);
        return { ip };
      } catch {
        await new Promise((r) => setTimeout(r, 1000));
      }
    }
    throw new Error("VM did not become ready");
  }
  async ssh(lease, p, ip, argv, timeoutSeconds, input) {
    const args = [
      "-o",
      "BatchMode=yes",
      "-o",
      "IdentitiesOnly=yes",
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-o",
      `UserKnownHostsFile=${path.join(this.config.stateDir, lease.id + ".known-hosts")}`,
      "-o",
      "ConnectTimeout=5",
      "-i",
      p.sshKeyFile,
      `${p.sshUser}@${ip}`,
      argv.map(quote).join(" "),
    ];
    const { stdout, stderr } = await new Promise((resolve, reject) => {
      const child = execFile(
        "/usr/bin/ssh",
        args,
        { timeout: timeoutSeconds * 1000, maxBuffer: 1024 * 1024 },
        (error, stdout, stderr) =>
          error
            ? reject(Object.assign(error, { stdout, stderr }))
            : resolve({ stdout, stderr }),
      );
      child.stdin.end(input ?? "");
    });
    return { exitCode: 0, output: stdout, stderr };
  }
  async run(lease, p, recipe) {
    try {
      if (recipe.github) {
        const { mintJit } = await import("./github.mjs");
        const jit = await mintJit(recipe.github, lease);
        this.onRuntimeChange?.();
        const script =
          "IFS= read -r jit; cd " +
          quote(recipe.github.runnerDir) +
          ' && exec ./run.sh --jitconfig \"$jit\"';
        return await this.ssh(
          lease,
          p,
          lease.runtime.ip,
          ["/bin/bash", "-c", script],
          recipe.timeoutSeconds,
          jit + "\n",
        );
      }
      return await this.ssh(
        lease,
        p,
        lease.runtime.ip,
        recipe.argv,
        recipe.timeoutSeconds,
      );
    } catch (error) {
      return {
        exitCode: Number.isInteger(error.code) ? error.code : 1,
        output: (error.stdout ?? "").slice(0, 1048576),
        stderr: (error.stderr ?? "").slice(0, 1048576),
        timedOut: !!error.killed,
      };
    }
  }
  async destroy(lease) {
    try {
      await this.cmd(lease.company, ["stop", lease.vm]);
    } catch {
      /* delete below verifies cleanup */
    }
    try {
      await this.cmd(lease.company, ["delete", lease.vm]);
    } catch (error) {
      const { stdout } = await this.cmd(lease.company, [
        "list",
        "--format",
        "json",
      ]);
      const entries = JSON.parse(stdout);
      if (
        !Array.isArray(entries) ||
        entries.some((v) => v.Name === lease.vm || v.name === lease.vm)
      )
        throw error;
    }
    const { removeRunner } = await import("./github.mjs");
    await removeRunner(lease);
    this.children.delete(lease.id);
  }
}

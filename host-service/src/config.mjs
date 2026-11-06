import fs from "node:fs";
import path from "node:path";
export const fail = (status, message) =>
  Object.assign(new Error(message), { status });
export function check(ok, message) {
  if (!ok) throw fail(400, message);
}
export function fields(value, allowed) {
  check(
    value && typeof value === "object" && !Array.isArray(value),
    "Expected object",
  );
  check(
    Object.keys(value).every((k) => allowed.includes(k)),
    "Unknown field (values omitted)",
  );
}
export const name = (v) =>
  typeof v === "string" && /^[a-z][a-z0-9-]{0,47}$/.test(v);
export function validateConfig(c) {
  fields(c, ["version", "stateDir", "tart", "listen", "capacity", "companies"]);
  check(
    c.version === 1 &&
      path.isAbsolute(c.stateDir ?? "") &&
      path.isAbsolute(c.tart ?? ""),
    "Invalid version or absolute paths",
  );
  fields(c.listen, ["host", "port"]);
  check(
    c.listen.host === "127.0.0.1" && Number.isInteger(c.listen.port),
    "Listen on loopback behind a private TLS proxy",
  );
  fields(c.capacity, ["macos", "cpus", "memoryMb"]);
  for (const v of Object.values(c.capacity))
    check(Number.isInteger(v) && v > 0, "Invalid host capacity");
  check(c.companies && Object.keys(c.companies).length, "Companies required");
  for (const [id, t] of Object.entries(c.companies)) {
    check(name(id), "Invalid company name");
    fields(t, ["tokenFile", "quota", "profiles"]);
    check(path.isAbsolute(t.tokenFile ?? ""), "Absolute token file required");
    fields(t.quota, ["leases", "cpus", "memoryMb"]);
    for (const v of Object.values(t.quota))
      check(Number.isInteger(v) && v > 0, "Invalid company quota");
    check(t.profiles && Object.keys(t.profiles).length, "Profiles required");
    for (const [key, p] of Object.entries(t.profiles)) {
      check(name(key), "Invalid profile name");
      fields(p, [
        "image",
        "os",
        "cpus",
        "memoryMb",
        "sshUser",
        "sshKeyFile",
        "recipes",
      ]);
      check(
        typeof p.image === "string" &&
          p.image.length &&
          !p.image.startsWith("-"),
        "Image required",
      );
      check(["macos", "linux"].includes(p.os), "Invalid guest OS");
      check(
        Number.isInteger(p.cpus) &&
          p.cpus > 0 &&
          Number.isInteger(p.memoryMb) &&
          p.memoryMb >= 512,
        "Invalid VM resources",
      );
      check(
        /^[a-z_][a-z0-9_-]*$/.test(p.sshUser) &&
          path.isAbsolute(p.sshKeyFile ?? ""),
        "Guest SSH configuration required",
      );
      check(p.recipes && typeof p.recipes === "object", "Recipes required");
      for (const [recipe, r] of Object.entries(p.recipes)) {
        check(name(recipe), "Invalid recipe name");
        fields(r, ["argv", "timeoutSeconds", "github"]);
        if (r.github) {
          fields(r.github, [
            "org",
            "tokenFile",
            "runnerDir",
            "labels",
            "runnerGroupId",
          ]);
          check(
            name(r.github.org) &&
              path.isAbsolute(r.github.tokenFile ?? "") &&
              path.isAbsolute(r.github.runnerDir ?? "") &&
              Array.isArray(r.github.labels) &&
              r.github.labels.every((v) => typeof v === "string") &&
              Number.isInteger(r.github.runnerGroupId),
            "Invalid GitHub runner recipe",
          );
        } else
          check(
            Array.isArray(r.argv) &&
              r.argv.length &&
              path.isAbsolute(r.argv[0]) &&
              r.argv.every((v) => typeof v === "string" && !v.includes("\0")),
            "Fixed recipe argv required",
          );
        check(
          Number.isInteger(r.timeoutSeconds) &&
            r.timeoutSeconds > 0 &&
            r.timeoutSeconds <= 3600,
          "Invalid recipe timeout",
        );
      }
    }
  }
  return c;
}
export function loadConfig(file) {
  return validateConfig(JSON.parse(fs.readFileSync(file, "utf8")));
}
export function readPrivate(file) {
  const stat = fs.lstatSync(file);
  check(
    stat.isFile() && !stat.isSymbolicLink() && !(stat.mode & 0o077),
    "Credential file must be a private regular file (0600)",
  );
  return fs.readFileSync(file, "utf8").trim();
}

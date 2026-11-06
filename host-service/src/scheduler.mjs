import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { check, fields, fail, name } from "./config.mjs";
const live = (l) =>
  ["starting", "ready", "running", "cleaning", "cleanup-failed"].includes(
    l.status,
  );
export class Scheduler {
  constructor(config, driver, clock = Date.now) {
    this.config = config;
    this.driver = driver;
    this.clock = clock;
    this.busy = new Set();
    this.tail = Promise.resolve();
    fs.mkdirSync(config.stateDir, { recursive: true, mode: 0o700 });
    this.file = path.join(config.stateDir, "leases.json");
    this.leases = fs.existsSync(this.file)
      ? JSON.parse(fs.readFileSync(this.file, "utf8"))
      : [];
    this.tasks = new Set();
    this.driver.onRuntimeChange = () => this.persist();
  }
  serial(fn) {
    const next = this.tail.then(fn);
    this.tail = next.catch(() => {});
    return next;
  }
  persist() {
    const tmp = this.file + ".tmp";
    const fd = fs.openSync(tmp, "w", 0o600);
    try {
      fs.writeFileSync(fd, JSON.stringify(this.leases));
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(tmp, this.file);
  }
  own(company, id) {
    const l = this.leases.find((l) => l.id === id && l.company === company);
    if (!l) throw fail(404, "Lease not found");
    return l;
  }
  view(l) {
    const { runtime, ...safe } = l;
    return safe;
  }
  list(company) {
    return this.leases
      .filter((l) => l.company === company)
      .map((l) => this.view(l));
  }
  async request(company, input) {
    fields(input, ["requestId", "profile", "kind", "ttlSeconds"]);
    check(
      name(input.requestId) && ["agent", "ci"].includes(input.kind),
      "Invalid request ID or kind",
    );
    check(
      Number.isInteger(input.ttlSeconds) &&
        input.ttlSeconds >= 30 &&
        input.ttlSeconds <= 14400,
      "TTL must be 30–14400 seconds",
    );
    const tenant = this.config.companies[company];
    const p = Object.hasOwn(tenant.profiles, input.profile)
      ? tenant.profiles[input.profile]
      : null;
    check(p, "Unknown company profile");
    check(
      p.cpus <= tenant.quota.cpus &&
        p.memoryMb <= tenant.quota.memoryMb &&
        p.cpus <= this.config.capacity.cpus &&
        p.memoryMb <= this.config.capacity.memoryMb,
      "Profile exceeds capacity",
    );
    return this.serial(() => {
      const existing = this.leases.find(
        (l) => l.company === company && l.requestId === input.requestId,
      );
      if (existing) {
        check(
          existing.profile === input.profile &&
            existing.kind === input.kind &&
            existing.ttlSeconds === input.ttlSeconds,
          "Request ID already used for different input",
        );
        return this.view(existing);
      }
      check(
        this.leases.filter(
          (l) => l.company === company && (live(l) || l.status === "queued"),
        ).length < 100,
        "Company queue limit reached",
      );
      const id = randomUUID();
      const now = this.clock();
      const l = {
        ...input,
        id,
        company,
        vm: `cvh-${company}-${id}`,
        status: "queued",
        createdAt: new Date(now).toISOString(),
        expiresAt: new Date(now + input.ttlSeconds * 1000).toISOString(),
        resources: {
          cpus: p.cpus,
          memoryMb: p.memoryMb,
          macos: p.os === "macos" ? 1 : 0,
        },
      };
      this.leases.push(l);
      this.persist();
      return this.view(l);
    });
  }
  fits(l) {
    const active = this.leases.filter(live);
    const tenant = this.config.companies[l.company];
    const used = (entries) =>
      entries.reduce(
        (a, l) => ({
          cpus: a.cpus + l.resources.cpus,
          memoryMb: a.memoryMb + l.resources.memoryMb,
          macos: a.macos + l.resources.macos,
        }),
        { cpus: 0, memoryMb: 0, macos: 0 },
      );
    const total = used(active),
      own = active.filter((v) => v.company === l.company),
      current = used(own);
    return (
      own.length < tenant.quota.leases &&
      ["cpus", "memoryMb", "macos"].every(
        (k) => total[k] + l.resources[k] <= this.config.capacity[k],
      ) &&
      ["cpus", "memoryMb"].every(
        (k) => current[k] + l.resources[k] <= tenant.quota[k],
      )
    );
  }
  background(task) {
    this.tasks.add(task);
    task.finally(() => this.tasks.delete(task)).catch(() => {});
  }
  async tick() {
    await this.serial(async () => {
      for (const l of this.leases)
        if (l.status === "cleanup-failed" && !this.busy.has(l.id))
          this.cleanup(l, "failed");
      for (const l of this.leases)
        if (Date.parse(l.expiresAt) <= this.clock()) {
          if (l.status === "queued") {
            l.status = "expired";
            this.persist();
          } else if (live(l) && !this.busy.has(l.id))
            this.cleanup(l, "expired");
        }
      // One admission per company per sweep; FIFO within a company. Rotating
      // last-served ordering prevents a single backlog monopolizing free slots.
      const companies = [
        ...new Set(
          this.leases
            .filter((l) => l.status === "queued")
            .map((l) => l.company),
        ),
      ];
      companies.sort(
        (a, b) => (this.lastServed?.[a] ?? 0) - (this.lastServed?.[b] ?? 0),
      );
      for (const company of companies) {
        const l = this.leases.find(
          (l) => l.company === company && l.status === "queued",
        );
        if (l && this.fits(l)) {
          l.status = "starting";
          this.persist();
          this.lastServed ??= {};
          this.lastServed[company] = this.clock();
          this.busy.add(l.id);
          this.background(
            (async () => {
              try {
                l.runtime = await this.driver.start(
                  l,
                  this.config.companies[l.company].profiles[l.profile],
                );
                l.status = "ready";
                this.persist();
              } catch {
                l.status = "cleanup-failed";
                this.persist();
              } finally {
                this.busy.delete(l.id);
                if (l.status === "cleanup-failed") this.cleanup(l, "failed");
              }
            })(),
          );
        }
      }
    });
  }
  cleanup(l, terminal = "released") {
    if (this.busy.has(l.id)) return;
    this.busy.add(l.id);
    l.status = "cleaning";
    this.persist();
    this.background(
      (async () => {
        try {
          await this.driver.destroy(l);
          l.status = terminal;
        } catch {
          l.status = "cleanup-failed";
        } finally {
          this.persist();
          this.busy.delete(l.id);
        }
      })(),
    );
  }
  async release(company, id) {
    return this.serial(() => {
      const l = this.own(company, id);
      if (this.busy.has(id)) throw fail(409, "Lease operation in progress");
      if (l.status === "queued") {
        l.status = "released";
        this.persist();
      } else if (live(l)) this.cleanup(l);
      return this.view(l);
    });
  }
  async renew(company, id) {
    return this.serial(() => {
      const l = this.own(company, id);
      check(
        ["queued", "ready", "running"].includes(l.status) &&
          Date.parse(l.expiresAt) > this.clock(),
        "Lease cannot be renewed",
      );
      l.expiresAt = new Date(this.clock() + l.ttlSeconds * 1000).toISOString();
      this.persist();
      return this.view(l);
    });
  }
  async run(company, id, input) {
    fields(input, ["recipe"]);
    check(name(input.recipe), "Invalid recipe");
    let l, p, recipe;
    await this.serial(() => {
      l = this.own(company, id);
      p = this.config.companies[company].profiles[l.profile];
      recipe = Object.hasOwn(p.recipes, input.recipe)
        ? p.recipes[input.recipe]
        : null;
      check(recipe, "Unknown recipe");
      if (l.status !== "ready" || this.busy.has(id))
        throw fail(409, "Lease not ready");
      check(
        Date.parse(l.expiresAt) - this.clock() > recipe.timeoutSeconds * 1000,
        "Renew lease before starting recipe",
      );
      l.status = "running";
      this.busy.add(id);
      this.persist();
    });
    try {
      return await this.driver.run(l, p, recipe);
    } finally {
      l.status = "ready";
      this.busy.delete(id);
      this.persist();
    }
  }
  async recover() {
    // Never adopt an opaque guest or resume old SSH operations after a restart.
    for (const l of this.leases.filter(live)) {
      this.cleanup(l, "interrupted");
    }
    await Promise.all([...this.tasks]);
  }
}

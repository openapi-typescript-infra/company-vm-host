import http from "node:http";
import { createHash, timingSafeEqual } from "node:crypto";
import { readPrivate, fail, fields } from "./config.mjs";
export function createServer(config, scheduler) {
  const tokens = Object.entries(config.companies).map(([company, c]) => {
    const value = readPrivate(c.tokenFile);
    if (value.length < 32) throw new Error("Company token too short");
    return {
      company,
      hash: createHash("sha256").update(`Bearer ${value}`).digest(),
    };
  });
  if (new Set(tokens.map((t) => t.hash.toString("hex"))).size !== tokens.length)
    throw new Error("Company tokens must be distinct");
  const server = http.createServer(async (req, res) => {
    const send = (status, value) => {
      res.writeHead(status, {
        "content-type": "application/json",
        "cache-control": "no-store",
        "x-company-host-api": "1",
      });
      res.end(JSON.stringify(value));
    };
    try {
      const hash = createHash("sha256")
        .update(req.headers.authorization ?? "")
        .digest();
      const identity = tokens.find((t) => timingSafeEqual(hash, t.hash));
      if (!identity) throw fail(401, "Unauthorized");
      const company = identity.company;
      const route = req.url?.match(
        /^\/v1\/leases(?:\/([a-f0-9-]{36})(?:\/(renew|run))?)?$/,
      );
      if (req.method === "GET" && req.url === "/v1/capabilities")
        return send(200, {
          apiVersion: 1,
          company,
          profiles: Object.keys(config.companies[company].profiles),
        });
      if (!route) throw fail(404, "Not found");
      const [, id, action] = route;
      if (req.method === "GET" && !action)
        return send(
          200,
          id
            ? scheduler.view(scheduler.own(company, id))
            : scheduler.list(company),
        );
      if (req.method === "DELETE" && id && !action)
        return send(200, await scheduler.release(company, id));
      if (req.method !== "POST") throw fail(404, "Not found");
      let raw = "";
      for await (const chunk of req) {
        raw += chunk;
        if (Buffer.byteLength(raw) > 4096) throw fail(413, "Request too large");
      }
      let input;
      try {
        input = JSON.parse(raw || "{}");
      } catch {
        throw fail(400, "Invalid JSON");
      }
      if (!id) return send(202, await scheduler.request(company, input));
      if (action === "renew") {
        fields(input, []);
        if (Object.keys(input).length)
          throw fail(400, "Renew takes no arguments");
        return send(200, await scheduler.renew(company, id));
      }
      if (action === "run")
        return send(200, await scheduler.run(company, id, input));
      throw fail(404, "Not found");
    } catch (error) {
      send(error.status ?? 500, {
        error: error.status ? error.message : "Host operation failed",
      });
    }
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  return server;
}

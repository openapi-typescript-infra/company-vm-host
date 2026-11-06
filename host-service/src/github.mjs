import { readPrivate } from "./config.mjs";
export async function mintJit(config, lease) {
  const token = readPrivate(config.tokenFile);
  const response = await fetch(
    `https://api.github.com/orgs/${encodeURIComponent(config.org)}/actions/runners/generate-jitconfig`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        accept: "application/vnd.github+json",
        "x-github-api-version": "2022-11-28",
      },
      body: JSON.stringify({
        name: `${lease.company}-${lease.id}`,
        runner_group_id: config.runnerGroupId,
        labels: config.labels,
        work_folder: "_work",
      }),
      signal: AbortSignal.timeout(30000),
    },
  );
  if (!response.ok) throw new Error("GitHub runner registration failed");
  const body = await response.json();
  if (typeof body.encoded_jit_config !== "string")
    throw new Error("Invalid GitHub runner registration");
  lease.runtime.githubRunner = {
    id: body.runner.id,
    org: config.org,
    tokenFile: config.tokenFile,
  };
  return body.encoded_jit_config;
}

export async function removeRunner(lease) {
  const r = lease.runtime?.githubRunner;
  if (!r) return;
  const response = await fetch(
    `https://api.github.com/orgs/${encodeURIComponent(r.org)}/actions/runners/${r.id}`,
    {
      method: "DELETE",
      headers: {
        authorization: `Bearer ${readPrivate(r.tokenFile)}`,
        accept: "application/vnd.github+json",
      },
      signal: AbortSignal.timeout(30000),
    },
  );
  if (!response.ok && response.status !== 404)
    throw new Error("Runner registration cleanup failed");
  delete lease.runtime.githubRunner;
}

import { randomUUID } from "node:crypto";

const coreURL = process.argv[2]?.replace(/\/$/, "");
const serviceToken = process.env.AGENT_CORE_SERVICE_TOKEN;
const userJWT = process.env.STAGING_USER_JWT;
if (!coreURL || !serviceToken || !userJWT) throw new Error("core URL, service token, and staging JWT are required");

const jwtPayload = userJWT.split(".")[1];
if (!jwtPayload) throw new Error("invalid staging JWT");
const userId = JSON.parse(Buffer.from(jwtPayload, "base64url").toString("utf8")).sub;
if (typeof userId !== "string") throw new Error("staging JWT has no subject");
const headers = {
  Authorization: `Bearer ${serviceToken}`,
  "X-Lamp-User": userId,
  "Content-Type": "application/json",
};

async function request(path, { method = "GET", body } = {}) {
  const response = await fetch(`${coreURL}${path}`, {
    method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(30_000),
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(`${method} ${path} returned ${response.status}: ${JSON.stringify(payload)}`);
  return payload;
}

await request("/health");
const run = await request("/debug/agent/run", {
  method: "POST",
  body: {
    context: {
      userId, sessionId: randomUUID(), requestId: randomUUID(), timezone: "Asia/Singapore", locale: "zh-CN",
      automationLevel: 0,
      authentication: { subject: userId, scopes: ["state:read", "activity:read", "agent_runs:read"] },
    },
    input: "安排复习高数",
    horizonDays: 1,
  },
});
if (run?.response?.status !== "succeeded" || !run?.replayBundle || !run?.trace?.events?.length) {
  throw new Error("debug run did not return response, trace, and replay bundle");
}
const runId = run.response.runId;
const runView = await request(`/agent/runs/${runId}`);
const trace = await request(`/agent/runs/${runId}/trace`);
const replay = await request("/debug/replay", { method: "POST", body: run.replayBundle });
if (runView?.status !== "succeeded" || trace?.runId !== runId || replay?.matched !== true) {
  throw new Error("debug trace or replay verification failed");
}
process.stdout.write(JSON.stringify({ ok: true, runId, replayId: replay.replayId, replayHash: replay.actualHash }) + "\n");

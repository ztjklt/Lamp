import { createHash, randomUUID } from "node:crypto";

const proposalBase = process.argv[2]?.replace(/\/$/, "");
const jwt = process.env.STAGING_USER_JWT;
const supabaseURL = process.env.STAGING_SUPABASE_URL?.replace(/\/$/, "");
const publishableKey = process.env.STAGING_PUBLISHABLE_KEY;
if (!proposalBase || !jwt || !supabaseURL || !publishableKey) {
  throw new Error("proposal URL, staging JWT, Supabase URL, and publishable key are required");
}

const headers = { Authorization: `Bearer ${jwt}`, apikey: publishableKey, "Content-Type": "application/json" };
const iso = (date) => date.toISOString();
const plusMinutes = (date, minutes) => new Date(date.getTime() + minutes * 60_000);
const fingerprint = (label) => createHash("sha256").update(label).digest("hex");
const taskId = randomUUID();
const taskTitle = `Staging smoke ${taskId.slice(0, 8)}`;
const now = new Date();
const start = new Date(Math.ceil(now.getTime() / 3_600_000) * 3_600_000 + 10 * 60_000);

async function jsonRequest(url, { method = "GET", body, expected = [200] } = {}) {
  const response = await fetch(url, {
    method,
    headers,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await response.text();
  let payload;
  try { payload = text.length === 0 ? null : JSON.parse(text); } catch { payload = { raw: text.slice(0, 500) }; }
  if (!expected.includes(response.status)) {
    throw new Error(`${method} ${url} returned ${response.status}: ${JSON.stringify(payload)}`);
  }
  return payload;
}

function assertProposal(payload, label) {
  if (payload?.schemaVersion !== 2 || payload?.status !== "proposal" ||
      typeof payload?.proposalId !== "string" || typeof payload?.previewHash !== "string" ||
      typeof payload?.confirmationToken !== "string") {
    throw new Error(`${label} did not return a confirmable v2 proposal`);
  }
}

const taskPayload = {
  id: taskId, parentID: null, kind: "task", title: taskTitle, detail: "staging smoke fixture",
  importance: 5, deadline: iso(plusMinutes(start, 600)), estimatedMinutes: 60,
  remainingMinutes: 60, progress: 0, isPaused: false,
};
const mutationId = randomUUID();
await jsonRequest(`${supabaseURL}/rest/v1/rpc/push_sync_batch`, {
  method: "POST",
  body: {
    p_device_id: randomUUID(),
    p_changes: [{
      entityType: "plan_node", entityId: taskId, entityVersion: 1, operation: "upsert",
      payload: taskPayload, contentHash: fingerprint(JSON.stringify(taskPayload)), clientMutationId: mutationId,
    }],
  },
});

async function stateVersion() {
  const rows = await jsonRequest(`${supabaseURL}/rest/v1/profiles?select=state_version&limit=1`);
  const value = rows?.[0]?.state_version;
  if (!Number.isInteger(value)) throw new Error("smoke user profile has no integer state_version");
  return value;
}

const preferences = {
  preferredSleepTime: "23:30", preferredWakeTime: "08:00", preferredFocusMinutes: 45,
  preferredBreakMinutes: 10, morningStudyPreference: 0.5, eveningStudyPreference: 0.5,
};
const task = {
  id: taskId, goalId: null, title: taskTitle, detail: "staging smoke fixture", importance: 5,
  deadline: iso(plusMinutes(start, 600)), estimatedMinutes: 60, remainingMinutes: 60,
  isPaused: false, isSplittable: true, minimumSessionMinutes: 15, maximumSessionMinutes: 90,
  preferredPeriods: ["afternoon"], dependencyIds: [], availableWindows: [],
};

const planRequestId = randomUUID();
const plan = await jsonRequest(`${proposalBase}/proposals/plan-day`, {
  method: "POST",
  body: {
    expectedStateVersion: await stateVersion(),
    request: {
      schemaVersion: 1, requestId: planRequestId, sourceFingerprint: fingerprint(planRequestId),
      requestedAt: iso(start), timezone: "Asia/Singapore", locale: "zh-CN",
      horizon: { start: iso(start), end: iso(plusMinutes(start, 720)) },
      tasks: [task], schedule: [], preferences,
    },
  },
});
assertProposal(plan, "plan-day");
const confirmed = await jsonRequest(`${proposalBase}/proposals/${plan.proposalId}/confirm`, {
  method: "POST",
  body: {
    previewHash: plan.previewHash, confirmationToken: plan.confirmationToken,
    expectedStateVersion: plan.expectedStateVersion, idempotencyKey: randomUUID(),
  },
});
if (confirmed?.status !== "applied") throw new Error("plan-day confirmation was not applied");
const confirmedView = await jsonRequest(`${proposalBase}/proposals/${plan.proposalId}`);
if (confirmedView?.status !== "applied") throw new Error("confirmed proposal could not be read back");

const eventId = randomUUID();
const missedBlockId = randomUUID();
const incomplete = await jsonRequest(`${proposalBase}/proposals/replan-incomplete`, {
  method: "POST",
  body: {
    expectedStateVersion: await stateVersion(),
    request: {
      schemaVersion: 1, eventId, sourceFingerprint: fingerprint(eventId),
      occurredAt: iso(plusMinutes(start, 45)), timezone: "Asia/Singapore", locale: "zh-CN",
      planningHorizon: { start: iso(start), end: iso(plusMinutes(start, 2_880)) },
      taskId, incompleteBlockId: missedBlockId, additionalMinutes: 60, tasks: [task],
      schedule: [{
        id: missedBlockId, taskId, title: taskTitle, startsAt: iso(start), endsAt: iso(plusMinutes(start, 60)),
        kind: "focus", state: "missed", locked: false, provenance: "Lamp",
      }],
      preferences,
    },
  },
});
assertProposal(incomplete, "replan-incomplete");
const rejectedIncomplete = await jsonRequest(`${proposalBase}/proposals/${incomplete.proposalId}/reject`, {
  method: "POST", body: {},
});
if (rejectedIncomplete?.status !== "rejected") throw new Error("incomplete proposal was not rejected");

const languageRequestId = randomUUID();
const languageStart = plusMinutes(start, 90);
const language = await jsonRequest(`${proposalBase}/proposals/replan-language`, {
  method: "POST",
  body: {
    expectedStateVersion: await stateVersion(),
    request: {
      schemaVersion: 1, requestId: languageRequestId, sourceFingerprint: fingerprint(languageRequestId),
      requestedAt: iso(languageStart), timezone: "Asia/Singapore", locale: "zh-CN",
      input: `今天有点累，${taskTitle}少做一点。`,
      planningHorizon: { start: iso(languageStart), end: iso(plusMinutes(languageStart, 300)) },
      tasks: [task],
      schedule: [{
        id: randomUUID(), taskId, title: taskTitle, startsAt: iso(plusMinutes(languageStart, 15)),
        endsAt: iso(plusMinutes(languageStart, 75)), kind: "focus", state: "planned",
        locked: false, provenance: "Lamp",
      }],
      preferences,
    },
  },
});
assertProposal(language, "replan-language");
if (typeof language.trace !== "object" || typeof language.trace?.model !== "object") {
  throw new Error("language proposal did not include model trace metadata");
}
const rejectedLanguage = await jsonRequest(`${proposalBase}/proposals/${language.proposalId}/reject`, {
  method: "POST", body: {},
});
if (rejectedLanguage?.status !== "rejected") throw new Error("language proposal was not rejected");

const confirmedBlockIds = Array.isArray(plan?.proposal?.blocks)
  ? plan.proposal.blocks.map((block) => block?.id).filter((id) => typeof id === "string")
  : [];
const cleanupChanges = [
  ...confirmedBlockIds.map((id) => ({
    entityType: "schedule_block", entityId: id, entityVersion: 2, operation: "delete",
    payload: null, contentHash: fingerprint(`deleted:${id}:2`), clientMutationId: randomUUID(),
  })),
  {
    entityType: "plan_node", entityId: taskId, entityVersion: 2, operation: "delete",
    payload: null, contentHash: fingerprint(`deleted:${taskId}:2`), clientMutationId: randomUUID(),
  },
];
await jsonRequest(`${supabaseURL}/rest/v1/rpc/push_sync_batch`, {
  method: "POST", body: { p_device_id: randomUUID(), p_changes: cleanupChanges },
});

process.stdout.write(JSON.stringify({
  ok: true,
  verticalSlices: ["plan-day:confirmed", "replan-incomplete:rejected", "replan-language:rejected"],
  confirmedStateVersion: confirmed.stateVersion,
}) + "\n");

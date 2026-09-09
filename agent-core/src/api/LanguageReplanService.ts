import { createHash } from "node:crypto";
import type { LLMProvider } from "../llm/LLMProvider.js";
import { LLMGateway } from "../llm/LLMGateway.js";
import type { LLMRequest } from "../llm/LLMRequest.js";
import type { LLMResponse } from "../llm/LLMResponse.js";
import { nullLogger } from "../observability/Logger.js";
import { StateSnapshotSchema } from "../agent/state/StateSnapshot.js";
import { FixedClock } from "../infrastructure/clock/FixedClock.js";
import { InMemoryPlanRevisionRepository } from "../infrastructure/repositories/InMemoryPlanRevisionRepository.js";
import { ReplanningEngine } from "../planning/ReplanningEngine.js";
import { SchedulingEngine } from "../planning/SchedulingEngine.js";
import { deterministicUuid } from "../planning/PlanningUtilities.js";
import type { ReplanningResult } from "../planning/ReplanningTypes.js";
import {
  LanguageReplanRequestSchema,
  LanguageReplanResponseSchema,
  LanguageWorkloadDecisionSchema,
  type LanguageReplanRequest,
  type LanguageReplanResponse,
  type LanguageWorkloadDecision,
} from "./LanguageReplanContract.js";
import { IdempotencyConflictError } from "./IncompleteReplanService.js";

export class InvalidLanguageDecisionError extends Error {}

export interface LanguageReplanServiceOptions {
  model: string;
}

export class LanguageReplanService {
  private readonly revisions = new InMemoryPlanRevisionRepository();
  private readonly completed = new Map<string, { digest: string; response: LanguageReplanResponse }>();
  private readonly llm: LLMGateway;

  constructor(provider: LLMProvider, private readonly options: LanguageReplanServiceOptions) {
    this.llm = new LLMGateway(provider, nullLogger);
  }

  async createProposal(input: unknown, userId = "lamp-local-client"): Promise<LanguageReplanResponse> {
    const request = LanguageReplanRequestSchema.parse(input);
    const key = `${userId}:${request.requestId}`;
    const digest = createHash("sha256").update(JSON.stringify(request)).digest("hex");
    const previous = this.completed.get(key);
    if (previous !== undefined) {
      if (previous.digest !== digest) throw new IdempotencyConflictError("request_id_reused_with_different_request");
      return structuredClone(previous.response);
    }

    const traceId = deterministicUuid(userId, request.requestId, "language-replan-trace");
    const runId = deterministicUuid(userId, request.requestId, "language-replan-run");
    const modelResponse = await this.llm.generate(decisionRequest(request, this.options.model, runId, traceId), { runId, traceId });
    const decision = parseAndValidateDecision(modelResponse, request);
    const state = buildState(request, userId, decision);
    const replanning = new ReplanningEngine(
      new SchedulingEngine(), this.revisions, new FixedClock(request.requestedAt),
    );
    const result = await replanning.replan({
      event: {
        eventId: deterministicUuid(userId, request.requestId, "language-replan-event"),
        userId,
        occurredAt: request.requestedAt,
        type: "USER_REQUEST_REPLAN",
        payload: { scope: decision.scope, taskIds: [decision.taskId] },
      },
      state,
      candidateLimit: 3,
      slotGranularityMinutes: 10,
      maximumDailyFocusMinutes: 360,
    });
    const response = toResponse(request, decision, modelResponse, traceId, result);
    this.completed.set(key, { digest, response });
    return structuredClone(response);
  }
}

function decisionRequest(
  request: LanguageReplanRequest,
  model: string,
  runId: string,
  traceId: string,
): LLMRequest {
  const context = {
    now: request.requestedAt,
    timezone: request.timezone,
    planningHorizon: request.planningHorizon,
    tasks: request.tasks.map((task) => ({
      id: task.id,
      title: task.title,
      remainingMinutes: task.remainingMinutes,
      minimumSessionMinutes: task.minimumSessionMinutes,
      maximumSessionMinutes: task.maximumSessionMinutes,
    })),
    movableFocusBlocks: request.schedule.filter((block) => block.kind === "focus" && !block.locked &&
      !["completed", "cancelled", "missed"].includes(block.state)).map((block) => ({
        id: block.id, taskId: block.taskId, title: block.title,
        startsAt: block.startsAt, endsAt: block.endsAt,
      })),
  };
  return {
    model,
    messages: [
      {
        role: "system",
        content: `You are Lamp's narrow workload-reduction controller. Return exactly one JSON object and no markdown.\nSchema: {"intent":"replan_schedule","action":"reduce_task_workload","taskId":"submitted UUID","targetMinutes":integer,"scope":"local"|"day","temporaryState":"tired","reasonCodes":["UPPER_SNAKE_CASE"],"confidence":0..1}.\nUse only a submitted task ID. The user must explicitly express fatigue and ask to reduce one named task. targetMinutes is the desired focus duration for that task in the supplied horizon, must be lower than its currently movable scheduled minutes, and must not be below its minimum session. For vague phrases such as 少学一点, choose approximately half of the current movable duration rounded to 10 minutes. Choose day when the user says today. Never perform calendar arithmetic, mutate state, or claim a plan was committed.`,
      },
      { role: "system", content: `DECISION_CONTEXT\n${JSON.stringify(context)}` },
      { role: "user", content: request.input },
    ],
    toolChoice: "none",
    responseFormat: "json_object",
    thinking: { enabled: false },
    temperature: 0,
    maxOutputTokens: 1_000,
    metadata: { runId, traceId, feature: "language_replan" },
  };
}

function parseAndValidateDecision(response: LLMResponse, request: LanguageReplanRequest): LanguageWorkloadDecision {
  if (response.toolCalls.length > 0 || response.content === null) {
    throw new InvalidLanguageDecisionError("model_did_not_return_a_structured_decision");
  }
  let raw: unknown;
  try {
    raw = JSON.parse(response.content);
  } catch {
    throw new InvalidLanguageDecisionError("model_decision_was_not_json");
  }
  const parsed = LanguageWorkloadDecisionSchema.safeParse(raw);
  if (!parsed.success) throw new InvalidLanguageDecisionError("model_decision_failed_schema_validation");
  const decision = parsed.data;
  const task = request.tasks.find((candidate) => candidate.id === decision.taskId);
  if (task === undefined || decision.confidence < 0.55) {
    throw new InvalidLanguageDecisionError("model_decision_is_not_grounded_in_active_state");
  }
  const scheduled = request.schedule.filter((block) => block.taskId === task.id && block.kind === "focus" &&
    !block.locked && !["completed", "cancelled", "missed"].includes(block.state) &&
    Date.parse(block.endsAt) > Date.parse(request.requestedAt));
  const scheduledMinutes = scheduled.reduce((sum, block) => sum + Math.round(
    (Date.parse(block.endsAt) - Math.max(Date.parse(block.startsAt), Date.parse(request.requestedAt))) / 60_000,
  ), 0);
  if (scheduledMinutes === 0 || decision.targetMinutes >= scheduledMinutes ||
      decision.targetMinutes < task.minimumSessionMinutes || decision.targetMinutes > task.remainingMinutes) {
    throw new InvalidLanguageDecisionError("model_target_minutes_are_not_a_safe_reduction");
  }
  return decision;
}

function buildState(request: LanguageReplanRequest, userId: string, decision: LanguageWorkloadDecision) {
  const affectedWindows = request.schedule.filter((block) => block.taskId === decision.taskId && block.kind === "focus" &&
    !block.locked && !["completed", "cancelled", "missed"].includes(block.state) &&
    Date.parse(block.endsAt) > Date.parse(request.requestedAt))
    .map((block) => ({
      start: new Date(Math.max(Date.parse(block.startsAt), Date.parse(request.requestedAt))).toISOString(),
      end: block.endsAt,
    }));
  return StateSnapshotSchema.parse({
    snapshotId: deterministicUuid(userId, request.requestId, "language-replan-snapshot"),
    userId,
    sourceRevision: 0,
    capturedAt: request.requestedAt,
    now: request.requestedAt,
    timezone: request.timezone,
    user: { id: userId, timezone: request.timezone, locale: request.locale, version: 0 },
    goals: [],
    activeTasks: request.tasks.map((task) => ({
      ...task,
      remainingMinutes: task.id === decision.taskId ? decision.targetMinutes : task.remainingMinutes,
      availableWindows: task.id === decision.taskId && affectedWindows.length > 0
        ? affectedWindows : task.availableWindows,
      version: 0,
    })),
    schedule: request.schedule.map((block) => ({
      ...block,
      reasonCodes: block.locked ? ["FIXED_EVENT_PROTECTION"] : [],
      revision: 0,
    })),
    upcomingEvents: [],
    preferences: {
      userId,
      preferredSleepTime: request.preferences.preferredSleepTime,
      preferredWakeTime: request.preferences.preferredWakeTime,
      defaultReminderMinutes: 5,
      preferredFocusMinutes: request.preferences.preferredFocusMinutes,
      preferredBreakMinutes: request.preferences.preferredBreakMinutes,
      morningStudyPreference: request.preferences.morningStudyPreference,
      eveningStudyPreference: request.preferences.eveningStudyPreference,
      version: 0,
    },
    energy: {
      level: 0.35,
      source: "user_explicit",
      capturedAt: request.requestedAt,
      expiresAt: request.planningHorizon.end,
    },
    planningHorizon: request.planningHorizon,
    lockedConstraints: [],
  });
}

function toResponse(
  request: LanguageReplanRequest,
  decision: LanguageWorkloadDecision,
  model: LLMResponse,
  traceId: string,
  result: ReplanningResult,
): LanguageReplanResponse {
  const trace = {
    traceId,
    model: { provider: model.provider, model: model.model },
    intent: "replan_schedule" as const,
    decision,
    diagnostics: result.diagnostics,
  };
  const base = {
    schemaVersion: 1 as const,
    requestId: request.requestId,
    sourceFingerprint: request.sourceFingerprint,
    commitRequired: true as const,
  };
  if (result.status !== "proposal") {
    return LanguageReplanResponseSchema.parse({ ...base, status: "no_feasible_plan", proposal: null, trace });
  }
  const changed = result.revision.changes.filter((change) => change.type !== "UNCHANGED").length;
  const selectedTaskTitle = request.tasks.find((task) => task.id === decision.taskId)?.title ?? "点名任务";
  return LanguageReplanResponseSchema.parse({
    ...base,
    status: "proposal",
    proposal: {
      id: result.revision.revisionId,
      sourceRequestId: request.requestId,
      scope: result.revision.scope,
      title: `让今天的“${selectedTaskTitle}”轻一点`,
      summary: `模型识别到临时疲惫；Planner 将目标专注量调整为 ${decision.targetMinutes} 分钟，共 ${changed} 处变化。`,
      reason: "临时状态：今天疲惫。只调整你点名的任务，不改变无关安排。",
      blocks: result.candidate.blocks,
      changes: result.revision.changes,
      warnings: result.revision.scope === decision.scope ? [] : ["原范围容量不足，Planner 已扩大调整范围。"],
    },
    trace,
  });
}

export class LocalLanguageDecisionProvider implements LLMProvider {
  readonly name = "local-language-fixture";

  async generate(request: LLMRequest): Promise<LLMResponse> {
    const contextMessage = request.messages.find((message) => message.content?.startsWith("DECISION_CONTEXT\n"));
    const userInput = request.messages.findLast((message) => message.role === "user")?.content ?? "";
    const context = JSON.parse(contextMessage?.content?.slice("DECISION_CONTEXT\n".length) ?? "{}") as {
      tasks?: Array<{ id: string; title: string; minimumSessionMinutes: number }>;
      movableFocusBlocks?: Array<{ taskId: string | null; title: string; startsAt: string; endsAt: string }>;
    };
    const task = context.tasks?.find((candidate) => userInput.includes(candidate.title) ||
      (userInput.includes("高数") && /高数|微积分/.test(candidate.title))) ?? context.tasks?.[0];
    if (task === undefined) throw new InvalidLanguageDecisionError("local_fixture_has_no_task");
    const scheduled = (context.movableFocusBlocks ?? []).filter((block) => block.taskId === task.id)
      .reduce((sum, block) => sum + (Date.parse(block.endsAt) - Date.parse(block.startsAt)) / 60_000, 0);
    let target = Math.max(task.minimumSessionMinutes, Math.round((scheduled / 2) / 10) * 10);
    if (target >= scheduled) target = Math.max(task.minimumSessionMinutes, scheduled - 10);
    const content = JSON.stringify({
      intent: "replan_schedule",
      action: "reduce_task_workload",
      taskId: task.id,
      targetMinutes: target,
      scope: "day",
      temporaryState: "tired",
      reasonCodes: ["USER_REPORTED_FATIGUE", "USER_REQUESTED_WORKLOAD_REDUCTION"],
      confidence: 0.96,
    });
    return {
      id: deterministicUuid(task.id, "local-language-response"),
      provider: this.name,
      model: request.model ?? "local-language-fixture",
      content,
      toolCalls: [],
      finishReason: "stop",
      usage: { inputTokens: 0, outputTokens: 0, totalTokens: 0, cacheHitTokens: 0, cacheMissTokens: 0 },
      latencyMs: 0,
    };
  }
}

import { describe, expect, it } from "vitest";
import type { LLMProvider } from "../src/llm/LLMProvider.js";
import type { LLMRequest } from "../src/llm/LLMRequest.js";
import type { LLMResponse } from "../src/llm/LLMResponse.js";
import { LLMGateway } from "../src/llm/LLMGateway.js";
import { ModelRouter } from "../src/llm/ModelRouter.js";
import { AgentLoop, type AgentLoopLimits } from "../src/agent/orchestrator/AgentLoop.js";
import { AgentOrchestrator } from "../src/agent/orchestrator/AgentOrchestrator.js";
import { StateEngine } from "../src/agent/state/StateEngine.js";
import { ToolRegistry } from "../src/agent/tools/ToolRegistry.js";
import { ToolExecutor } from "../src/agent/tools/ToolExecutor.js";
import { ToolValidator } from "../src/agent/tools/ToolValidator.js";
import { PermissionPolicy, PolicyEngine, ToolRiskPolicy } from "../src/agent/policies/PolicyEngine.js";
import { SchedulingEngine } from "../src/planning/SchedulingEngine.js";
import { ReplanningEngine } from "../src/planning/ReplanningEngine.js";
import { FixedClock } from "../src/infrastructure/clock/FixedClock.js";
import { TimeZoneService } from "../src/infrastructure/time/TimeZoneService.js";
import { InMemoryStateRepository, InMemoryStateSnapshotRepository } from "../src/infrastructure/repositories/InMemoryStateRepositories.js";
import { InMemoryAgentRunRepository } from "../src/infrastructure/repositories/InMemoryAgentRunRepository.js";
import { InMemoryHistoryRepository } from "../src/infrastructure/repositories/InMemoryHistoryRepository.js";
import { InMemoryAuditLogRepository } from "../src/infrastructure/repositories/InMemoryAuditLogRepository.js";
import { InMemoryPlanRevisionRepository } from "../src/infrastructure/repositories/InMemoryPlanRevisionRepository.js";
import { AuditLog } from "../src/observability/AuditLog.js";
import { nullLogger } from "../src/observability/Logger.js";
import { createReadTools } from "../src/tools/read/ReadTools.js";
import { fixtureIds, makeStateSnapshot } from "./fixtures/StateFixture.js";
import { LampError } from "../src/errors/LampError.js";

const defaultLimits: AgentLoopLimits = {
  maxModelTurns: 8,
  maxToolCalls: 20,
  maxPlanningAttempts: 3,
  maxRepairAttempts: 2,
  maxRunDurationMs: 60_000,
};

function intent(confidence = 0.95) {
  return {
    intent: "plan_schedule",
    confidence,
    entities: { taskIds: [fixtureIds.task] },
    requiresClarification: confidence < 0.55,
  };
}

function decision(action: string) {
  return {
    goal: "plan_today",
    action,
    reasonCodes: ["USER_REQUESTED_PLAN"],
    confidence: 0.95,
    expectedEffect: { affectedTasks: [fixtureIds.task] },
  };
}

function generatePlanAction(overrides: Record<string, unknown> = {}) {
  return {
    type: "generate_plan",
    intent: intent(),
    decision: decision("generate_schedule_candidates"),
    planning: {
      taskIds: [fixtureIds.task],
      horizon: { start: "2026-09-08T08:00:00Z", end: "2026-09-08T16:00:00Z" },
      scope: "day",
      candidateLimit: 2,
      slotGranularityMinutes: 10,
      maximumDailyFocusMinutes: 360,
      ...overrides,
    },
  };
}

function respondAction(message = "已生成两个可行方案，请选择。") {
  return { type: "respond", intent: intent(), decision: decision("present_plan_proposal"), message };
}

function response(index: number, content: string | null, toolCalls: LLMResponse["toolCalls"] = []): LLMResponse {
  return {
    id: `response-${index}`,
    provider: "mock",
    model: "mock-flash",
    content,
    toolCalls,
    finishReason: toolCalls.length > 0 ? "tool_calls" : "stop",
    usage: { inputTokens: 10, outputTokens: 5, totalTokens: 15, cacheHitTokens: 0, cacheMissTokens: 10 },
    latencyMs: 4,
  };
}

function harness(
  responses: Array<LLMResponse | Error>,
  options: { limits?: Partial<AgentLoopLimits>; monotonicNow?: () => number } = {},
) {
  const snapshot = makeStateSnapshot();
  const clock = new FixedClock("2026-09-08T08:00:00Z");
  let idCounter = 400;
  const ids = { next: () => `00000000-0000-4000-8000-${String(idCounter++).padStart(12, "0")}` };
  const stateRepository = new InMemoryStateRepository([{
    user: snapshot.user,
    state: {
      userVersion: snapshot.user.version,
      sourceRevision: snapshot.sourceRevision,
      goals: snapshot.goals,
      activeTasks: snapshot.activeTasks,
      schedule: snapshot.schedule,
      upcomingEvents: snapshot.upcomingEvents,
      preferences: snapshot.preferences,
      energy: snapshot.energy,
      lockedConstraints: snapshot.lockedConstraints,
    },
  }]);
  const stateEngine = new StateEngine(
    stateRepository,
    stateRepository,
    new InMemoryStateSnapshotRepository(),
    clock,
    ids,
    new TimeZoneService(),
    { defaultHorizonDays: 1 },
  );
  const requests: LLMRequest[] = [];
  const queue = [...responses];
  const provider: LLMProvider = {
    name: "mock",
    generate: async (request) => {
      requests.push(structuredClone(request));
      const next = queue.shift();
      if (next === undefined) throw new Error("mock response queue exhausted");
      if (next instanceof Error) throw next;
      return next;
    },
  };
  const registry = new ToolRegistry();
  for (const tool of createReadTools()) registry.register(tool);
  const auditRepository = new InMemoryAuditLogRepository();
  const toolExecutor = new ToolExecutor(
    registry,
    new ToolValidator(),
    new PolicyEngine([new PermissionPolicy(), new ToolRiskPolicy()]),
    new AuditLog(auditRepository, clock, ids),
    clock,
    nullLogger,
  );
  const runtime = { clock, ids, ...(options.monotonicNow === undefined ? {} : { monotonicNow: options.monotonicNow }) };
  const revisionRepository = new InMemoryPlanRevisionRepository();
  const loop = new AgentLoop(
    new LLMGateway(provider, nullLogger),
    registry,
    toolExecutor,
    new SchedulingEngine(),
    new ModelRouter("mock-flash", "mock-pro"),
    nullLogger,
    runtime,
    new ReplanningEngine(new SchedulingEngine(), revisionRepository, clock),
  );
  const runRepository = new InMemoryAgentRunRepository();
  const history = new InMemoryHistoryRepository();
  const limits = { ...defaultLimits, ...options.limits };
  const orchestrator = new AgentOrchestrator(
    stateEngine,
    loop,
    runRepository,
    history,
    history,
    { clock, ids },
    limits,
    nullLogger,
  );
  const request = {
    context: {
      userId: "user-1",
      sessionId: "session-1",
      requestId: "request-1",
      timezone: "Asia/Singapore",
      locale: "zh-CN",
      automationLevel: 0,
      authentication: { subject: "user-1", scopes: ["state:read", "activity:read", "agent_runs:read"] },
    },
    input: "根据现有任务和日历安排今天的学习",
    horizonDays: 1,
  };
  return { orchestrator, request, requests, runRepository, auditRepository, revisionRepository };
}

describe("AgentOrchestrator finite loop", () => {
  it("connects intent, state, LLM, planning policy and deterministic planner into a proposal", async () => {
    const setup = harness([
      response(1, JSON.stringify(generatePlanAction())),
      response(2, JSON.stringify(respondAction())),
    ]);
    const result = await setup.orchestrator.execute(setup.request);

    expect(result.status).toBe("succeeded");
    expect(result.proposal).toMatchObject({ baseStateRevision: 8, candidates: expect.any(Array) });
    const candidates = result.proposal?.["candidates"] as unknown[];
    expect(candidates.length).toBeGreaterThan(0);
    const record = await setup.runRepository.getById(result.runId);
    expect(record).toMatchObject({
      finalStatus: "succeeded",
      intent: { intent: "plan_schedule" },
      modelCalls: [{ status: "succeeded" }, { status: "succeeded" }],
      plannerRuns: [{ status: "success", candidateCount: expect.any(Number) }],
    });
    expect(record?.decisions).toHaveLength(2);
    expect(record?.policyDecisions).toContainEqual(expect.objectContaining({ reasonCode: "PLAN_PROPOSAL_ALLOWED" }));
    expect(JSON.stringify(record)).not.toContain("reasoningContent");
  });

  it("round-trips assistant tool calls and observations before the next decision", async () => {
    const setup = harness([
      response(1, null, [{ id: "provider-call-1", name: "get_tasks", arguments: {} }]),
      response(2, JSON.stringify(respondAction("当前有一个待处理任务。"))),
    ]);
    const result = await setup.orchestrator.execute(setup.request);

    expect(result.status).toBe("succeeded");
    expect(setup.requests).toHaveLength(2);
    expect(setup.requests[1]?.messages).toContainEqual(expect.objectContaining({
      role: "assistant",
      toolCalls: [{ id: "provider-call-1", name: "get_tasks", arguments: {} }],
    }));
    expect(setup.requests[1]?.messages).toContainEqual(expect.objectContaining({
      role: "tool",
      toolCallId: "provider-call-1",
      name: "get_tasks",
    }));
    const record = await setup.runRepository.getById(result.runId);
    expect(record?.toolCalls).toHaveLength(1);
    expect(record?.policyDecisions).toHaveLength(2);
    expect(await setup.auditRepository.listByRun(result.runId)).toHaveLength(1);
  });

  it("repairs invalid structured output within the configured bound", async () => {
    const setup = harness([
      response(1, "not-json"),
      response(2, JSON.stringify(respondAction("已恢复。"))),
    ]);
    const result = await setup.orchestrator.execute(setup.request);
    expect(result.status).toBe("succeeded");
    expect(setup.requests[1]?.messages).toContainEqual(expect.objectContaining({
      role: "system",
      content: expect.stringContaining("REPAIR_REQUIRED"),
    }));
  });

  it("retries a retryable model failure within the model-turn limit and records both calls", async () => {
    const setup = harness([
      new LampError({ code: "MODEL_TIMEOUT", message: "fixture timeout", retryable: true }),
      response(2, JSON.stringify(respondAction("重试成功。"))),
    ]);
    const result = await setup.orchestrator.execute(setup.request);
    expect(result.status).toBe("succeeded");
    const record = await setup.runRepository.getById(result.runId);
    expect(record?.modelCalls.map((call) => call.status)).toEqual(["failed", "succeeded"]);
    expect(record?.modelCalls[0]?.errorCode).toBe("MODEL_TIMEOUT");
  });

  it("asks the user when planning confidence is below policy threshold", async () => {
    const action = generatePlanAction();
    action.intent = intent(0.4);
    const setup = harness([response(1, JSON.stringify(action))]);
    const result = await setup.orchestrator.execute(setup.request);
    expect(result).toMatchObject({ status: "confirmation_required", message: expect.stringContaining("歧义") });
    const record = await setup.runRepository.getById(result.runId);
    expect(record?.finalStatus).toBe("confirmation_required");
    expect(record?.plannerRuns).toHaveLength(0);
  });

  it("safe-aborts instead of returning a partial plan after no feasible plan", async () => {
    const setup = harness(
      [response(1, JSON.stringify(generatePlanAction({ maximumDailyFocusMinutes: 60 })))],
      { limits: { maxPlanningAttempts: 1 } },
    );
    const result = await setup.orchestrator.execute(setup.request);
    expect(result).toMatchObject({ status: "safe_aborted", error: { code: "NO_FEASIBLE_PLAN" } });
    expect(result.proposal).toBeUndefined();
  });

  it("safe-aborts before executing tool calls beyond the configured limit", async () => {
    const setup = harness([
      response(1, null, [
        { id: "provider-call-1", name: "get_tasks", arguments: {} },
        { id: "provider-call-2", name: "get_schedule", arguments: { start: "2026-09-08T08:00:00Z", end: "2026-09-08T16:00:00Z" } },
      ]),
    ], { limits: { maxToolCalls: 1 } });
    const result = await setup.orchestrator.execute(setup.request);
    expect(result).toMatchObject({ status: "safe_aborted", error: { code: "RATE_LIMIT" } });
    const record = await setup.runRepository.getById(result.runId);
    expect(record?.toolCalls).toHaveLength(0);
  });

  it("enforces the overall run duration boundary", async () => {
    const values = [0, 1, 200];
    const setup = harness([response(1, JSON.stringify(respondAction()))], {
      limits: { maxRunDurationMs: 100 },
      monotonicNow: () => values.shift() ?? 200,
    });
    const result = await setup.orchestrator.execute(setup.request);
    expect(result).toMatchObject({ status: "safe_aborted", error: { code: "MODEL_TIMEOUT" } });
  });

  it("routes replan_schedule through the revisioned stability engine", async () => {
    const replan = generatePlanAction();
    replan.intent = { ...intent(), intent: "replan_schedule" };
    replan.decision = decision("replan_schedule");
    const review = respondAction("重规划提案已生成。");
    review.intent = { ...intent(), intent: "replan_schedule" };
    const setup = harness([
      response(1, JSON.stringify(replan)),
      response(2, JSON.stringify(review)),
    ]);
    const result = await setup.orchestrator.execute(setup.request);
    expect(result.status).toBe("succeeded");
    expect(result.proposal?.["revision"]).toMatchObject({ status: "proposed", revision: 1 });
    const revision = result.proposal?.["revision"] as { planId: string };
    expect(await setup.revisionRepository.list(revision.planId)).toHaveLength(1);
    const record = await setup.runRepository.getById(result.runId);
    expect(record?.intent?.intent).toBe("replan_schedule");
  });
});

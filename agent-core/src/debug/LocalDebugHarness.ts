import type { LLMProvider } from "../llm/LLMProvider.js";
import type { LLMRequest } from "../llm/LLMRequest.js";
import type { LLMResponse } from "../llm/LLMResponse.js";
import { LLMGateway } from "../llm/LLMGateway.js";
import { AgentLoop, type AgentLoopLimits } from "../agent/orchestrator/AgentLoop.js";
import { AgentOrchestrator, AgentRequestSchema, type AgentRequest } from "../agent/orchestrator/AgentOrchestrator.js";
import type { AgentResponse } from "../agent/schemas/AgentResponse.js";
import type { Intent } from "../agent/schemas/Intent.js";
import { StateEngine } from "../agent/state/StateEngine.js";
import { StateSnapshotSchema, type StateSnapshot } from "../agent/state/StateSnapshot.js";
import { PolicyEngine, PermissionPolicy, ToolRiskPolicy } from "../agent/policies/PolicyEngine.js";
import { ToolExecutor } from "../agent/tools/ToolExecutor.js";
import { ToolRegistry } from "../agent/tools/ToolRegistry.js";
import { ToolValidator } from "../agent/tools/ToolValidator.js";
import { InMemoryAgentRunRepository } from "../infrastructure/repositories/InMemoryAgentRunRepository.js";
import { InMemoryAuditLogRepository } from "../infrastructure/repositories/InMemoryAuditLogRepository.js";
import { InMemoryHistoryRepository } from "../infrastructure/repositories/InMemoryHistoryRepository.js";
import { InMemoryPlanRevisionRepository } from "../infrastructure/repositories/InMemoryPlanRevisionRepository.js";
import { InMemoryStateRepository, InMemoryStateSnapshotRepository } from "../infrastructure/repositories/InMemoryStateRepositories.js";
import { FixedClock } from "../infrastructure/clock/FixedClock.js";
import type { IdGenerator } from "../infrastructure/id/IdGenerator.js";
import { TimeZoneService } from "../infrastructure/time/TimeZoneService.js";
import { AuditLog } from "../observability/AuditLog.js";
import { nullLogger } from "../observability/Logger.js";
import { TraceViewBuilder } from "../observability/TraceView.js";
import { ModelRouter } from "../llm/ModelRouter.js";
import { SchedulingEngine } from "../planning/SchedulingEngine.js";
import { ReplanningEngine } from "../planning/ReplanningEngine.js";
import { deterministicUuid } from "../planning/PlanningUtilities.js";
import { createReadTools } from "../tools/read/ReadTools.js";
import { StudentNormalDay } from "../evals/fixtures/EvalFixtures.js";
import type { DebugAgentService, DebugRunArtifact } from "./DebugApi.js";
import { ReplayBundleSchema, ReplayRecorder, ReplayRunner, type ReplayBundle, type ReplayResult } from "./Replay.js";

const DEBUG_LIMITS: AgentLoopLimits = {
  maxModelTurns: 8,
  maxToolCalls: 20,
  maxPlanningAttempts: 3,
  maxRepairAttempts: 2,
  maxRunDurationMs: 60_000,
};

export class LocalDebugHarness implements DebugAgentService {
  readonly runs = new InMemoryAgentRunRepository();
  readonly snapshots = new InMemoryStateSnapshotRepository();
  readonly audits = new InMemoryAuditLogRepository();
  private readonly traceBuilder = new TraceViewBuilder();

  async run(rawRequest: AgentRequest): Promise<DebugRunArtifact> {
    const request = AgentRequestSchema.parse(rawRequest);
    const state = stateForRequest(request);
    return this.execute(request, state, new DebugMockProvider(request.input, state));
  }

  async replay(rawBundle: unknown): Promise<ReplayResult> {
    const bundle = ReplayBundleSchema.parse(rawBundle);
    return new ReplayRunner().replay(bundle, {
      execute: async (value, provider) => ({ response: (await this.execute(value.request, value.state, provider)).response }),
    });
  }

  private async execute(request: AgentRequest, sourceState: StateSnapshot, provider: LLMProvider): Promise<DebugRunArtifact> {
    const clock = new FixedClock(sourceState.now);
    const ids = new RequestIdGenerator(request.context.requestId);
    const stateRepository = new InMemoryStateRepository([{
      user: sourceState.user,
      state: {
        userVersion: sourceState.user.version,
        sourceRevision: sourceState.sourceRevision,
        goals: sourceState.goals,
        activeTasks: sourceState.activeTasks,
        schedule: sourceState.schedule,
        upcomingEvents: sourceState.upcomingEvents,
        preferences: sourceState.preferences,
        energy: sourceState.energy,
        lockedConstraints: sourceState.lockedConstraints,
      },
    }]);
    const stateEngine = new StateEngine(
      stateRepository,
      stateRepository,
      this.snapshots,
      clock,
      ids,
      new TimeZoneService(),
      { defaultHorizonDays: request.horizonDays ?? 1 },
    );
    const registry = new ToolRegistry();
    for (const tool of createReadTools()) registry.register(tool);
    const history = new InMemoryHistoryRepository();
    const captured = new CapturingProvider(provider);
    const planner = new SchedulingEngine();
    const loop = new AgentLoop(
      new LLMGateway(captured, nullLogger),
      registry,
      new ToolExecutor(
        registry,
        new ToolValidator(),
        new PolicyEngine([new PermissionPolicy(), new ToolRiskPolicy()]),
        new AuditLog(this.audits, clock, ids),
        clock,
        nullLogger,
      ),
      planner,
      new ModelRouter("debug-flash", "debug-pro"),
      nullLogger,
      { clock, ids },
      new ReplanningEngine(planner, new InMemoryPlanRevisionRepository(), clock),
    );
    const orchestrator = new AgentOrchestrator(
      stateEngine,
      loop,
      this.runs,
      history,
      history,
      { clock, ids },
      DEBUG_LIMITS,
      nullLogger,
    );
    const response = await orchestrator.execute(request);
    const run = await this.runs.getById(response.runId);
    if (!run) throw new Error("Debug run record was not persisted");
    const snapshot = run.stateSnapshotId === undefined ? null : await this.snapshots.getById(run.stateSnapshotId);
    if (!snapshot) throw new Error("Debug state snapshot was not persisted");
    const trace = this.traceBuilder.build(run, snapshot, await this.audits.listByRun(run.runId));
    const replayBundle = new ReplayRecorder().create({
      replayId: deterministicUuid(run.runId, "replay"),
      capturedAt: clock.now().toString(),
      request,
      state: snapshot,
      modelResponses: captured.responses,
      response,
    });
    return { response, trace, replayBundle };
  }
}

class RequestIdGenerator implements IdGenerator {
  private index = 0;

  constructor(private readonly seed: string) {}

  next(): string {
    return deterministicUuid(this.seed, "debug-id", String(this.index++));
  }
}

class CapturingProvider implements LLMProvider {
  readonly name: string;
  readonly responses: LLMResponse[] = [];

  constructor(private readonly target: LLMProvider) {
    this.name = target.name;
  }

  async generate(request: LLMRequest): Promise<LLMResponse> {
    const response = await this.target.generate(request);
    this.responses.push(structuredClone(response));
    return response;
  }
}

class DebugMockProvider implements LLMProvider {
  readonly name = "debug-mock";
  private turn = 0;

  constructor(
    private readonly userInput: string,
    private readonly state: StateSnapshot,
  ) {}

  async generate(): Promise<LLMResponse> {
    const currentTurn = this.turn++;
    const tool = selectedReadTool(this.userInput);
    if (currentTurn === 0 && tool !== null) return response(currentTurn, null, [{
      id: `debug-tool-${currentTurn}`,
      name: tool,
      arguments: toolArguments(tool, this.state),
    }]);
    const intent = inferredIntent(this.userInput);
    if (currentTurn === 0 && intent === "plan_schedule") {
      const task = this.state.activeTasks[0];
      if (!task) throw new Error("Debug fixture has no task to plan");
      return response(currentTurn, JSON.stringify({
        type: "generate_plan",
        intent: intentValue(intent, task.id),
        decision: decision("generate_schedule_candidates", task.id),
        planning: {
          taskIds: [task.id],
          horizon: this.state.planningHorizon,
          scope: "day",
          candidateLimit: 3,
          slotGranularityMinutes: 10,
          maximumDailyFocusMinutes: 360,
        },
      }));
    }
    const taskId = this.state.activeTasks[0]?.id;
    return response(currentTurn, JSON.stringify({
      type: "respond",
      intent: intentValue(intent, taskId),
      decision: decision(intent === "plan_schedule" ? "present_plan_proposal" : "present_debug_result", taskId),
      message: intent === "plan_schedule" ? "已生成可验证的候选计划。" : "已完成本地调试查询。",
    }));
  }
}

function stateForRequest(request: AgentRequest): StateSnapshot {
  const state = StudentNormalDay(900);
  if (request.context.userId !== state.userId || request.context.timezone !== state.timezone) {
    throw new Error("Local debug fixture requires eval-user in Asia/Singapore");
  }
  return StateSnapshotSchema.parse(state);
}

function inferredIntent(input: string): Intent["intent"] {
  if (/重新|调整/.test(input)) return "replan_schedule";
  if (/安排|复习|计划/.test(input)) return "plan_schedule";
  if (/任务|日历|空闲|几点|查看|查询/.test(input)) return "query_schedule";
  return "chat";
}

function intentValue(intent: Intent["intent"], taskId?: string): Intent {
  return {
    intent,
    confidence: 0.95,
    entities: taskId === undefined ? {} : { taskIds: [taskId] },
    requiresClarification: false,
  };
}

function decision(action: string, taskId?: string) {
  return {
    goal: "debug_agent_request",
    action,
    reasonCodes: ["DEBUG_HARNESS_REQUEST"],
    confidence: 0.95,
    expectedEffect: taskId === undefined ? {} : { affectedTasks: [taskId] },
  };
}

function selectedReadTool(input: string): string | null {
  if (/几点/.test(input)) return "get_current_time";
  if (/日历/.test(input)) return "get_calendar_events";
  if (/空闲/.test(input)) return "get_free_slots";
  if (/查看.*任务|查询.*任务/.test(input)) return "get_tasks";
  return null;
}

function toolArguments(tool: string, state: StateSnapshot): Record<string, unknown> {
  if (tool === "get_calendar_events") return state.planningHorizon;
  if (tool === "get_free_slots") return { ...state.planningHorizon, minimumDurationMinutes: 30 };
  return {};
}

function response(turn: number, content: string | null, toolCalls: LLMResponse["toolCalls"] = []): LLMResponse {
  return {
    id: `debug-response-${turn}`,
    provider: "debug-mock",
    model: "debug-local",
    content,
    toolCalls,
    finishReason: toolCalls.length > 0 ? "tool_calls" : "stop",
    usage: { inputTokens: 10, outputTokens: 5, totalTokens: 15, cacheHitTokens: 0, cacheMissTokens: 10 },
    latencyMs: 1,
  };
}

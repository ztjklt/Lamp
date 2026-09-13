import { z } from "zod";
import { AgentRequestSchema, type AgentRequest } from "../agent/orchestrator/AgentOrchestrator.js";
import type { AgentRunRecord } from "../agent/schemas/AgentRun.js";
import type { AgentResponse } from "../agent/schemas/AgentResponse.js";
import { UUIDSchema } from "../agent/schemas/Common.js";
import type { AgentRunRepository } from "../domain/repositories/AgentRunRepository.js";
import type { StateSnapshotRepository } from "../domain/repositories/StateRepositories.js";
import { LampError } from "../errors/LampError.js";
import type { AuditLogRepository } from "../observability/AuditLog.js";
import { TraceViewBuilder, type TraceView } from "../observability/TraceView.js";
import {
  PlanningRequestSchema,
  ProposedScheduleBlockSchema,
  type PlanningResult,
  type RawScheduleCandidate,
} from "../planning/PlanningTypes.js";
import { PlanValidator, type PlanValidationResult } from "../planning/PlanValidator.js";
import { SchedulingEngine } from "../planning/SchedulingEngine.js";
import type { ReplayBundle, ReplayResult } from "./Replay.js";

export interface DebugRunArtifact {
  response: AgentResponse;
  trace: TraceView;
  replayBundle: ReplayBundle;
}

export interface DebugAgentService {
  run(request: AgentRequest): Promise<DebugRunArtifact>;
  replay(bundle: unknown): Promise<ReplayResult>;
}

export interface DebugApiOptions {
  enabled: boolean;
  environment: "development" | "test" | "staging" | "production";
}

export interface DebugApiRequest {
  method: "GET" | "POST";
  path: string;
  authenticatedUserId: string;
  body?: unknown;
}

export interface DebugRunView {
  runId: string;
  traceId: string;
  stateSnapshotId?: string;
  startedAt: string;
  endedAt?: string;
  status: AgentRunRecord["finalStatus"];
  intent?: string;
  modelCalls: number;
  toolCalls: number;
  policyDecisions: number;
  plannerRuns: number;
  tokenUsage: AgentRunRecord["tokenUsage"];
  estimatedCost: number;
  errorCode?: string;
}

const DebugValidationRequestSchema = z.object({
  request: PlanningRequestSchema,
  candidate: z.object({
    id: UUIDSchema,
    blocks: z.array(ProposedScheduleBlockSchema),
    changedExistingBlocks: z.number().int().nonnegative(),
    scheduleChangeCost: z.number().nonnegative().optional(),
  }).strict(),
}).strict();

/** Protocol-independent API surface; an HTTP adapter can map these methods to the documented routes. */
export class DebugApi {
  constructor(
    private readonly options: DebugApiOptions,
    private readonly agent: DebugAgentService,
    private readonly runs: AgentRunRepository,
    private readonly snapshots: StateSnapshotRepository,
    private readonly audits: AuditLogRepository,
    private readonly traceBuilder = new TraceViewBuilder(),
    private readonly planner = new SchedulingEngine(),
    private readonly validator = new PlanValidator(),
  ) {}

  async handle(request: DebugApiRequest): Promise<unknown> {
    this.assertEnabled();
    if (request.method === "POST" && request.path === "/debug/agent/run") {
      const agentRequest = AgentRequestSchema.parse(request.body);
      this.assertStateOwner(request.authenticatedUserId, agentRequest.context.userId);
      return this.runAgent(request.authenticatedUserId, agentRequest);
    }
    if (request.method === "POST" && request.path === "/debug/replay") {
      return this.replay(request.authenticatedUserId, request.body);
    }
    if (request.method === "POST" && request.path === "/planning/simulate") {
      return this.simulatePlanning(request.authenticatedUserId, request.body);
    }
    if (request.method === "POST" && request.path === "/planning/validate") {
      return this.validatePlanning(request.authenticatedUserId, request.body);
    }
    const traceMatch = request.path.match(/^\/agent\/runs\/([0-9a-f-]+)\/trace$/i);
    if (request.method === "GET" && traceMatch?.[1]) return this.getTrace(request.authenticatedUserId, traceMatch[1]);
    const runMatch = request.path.match(/^\/agent\/runs\/([0-9a-f-]+)$/i);
    if (request.method === "GET" && runMatch?.[1]) return this.getRun(request.authenticatedUserId, runMatch[1]);
    throw new LampError({
      code: "VALIDATION_ERROR",
      message: `Unsupported debug route: ${request.method} ${request.path}`,
      safeMessage: "不支持的 Debug API 路由。",
      statusCode: 404,
    });
  }

  async runAgent(authenticatedUserId: string, rawRequest: unknown): Promise<DebugRunArtifact> {
    this.assertEnabled();
    const request = AgentRequestSchema.parse(rawRequest);
    this.assertStateOwner(authenticatedUserId, request.context.userId);
    return this.agent.run(request);
  }

  async getRun(authenticatedUserId: string, rawRunId: string): Promise<DebugRunView> {
    this.assertEnabled();
    const run = await this.ownedRun(authenticatedUserId, rawRunId);
    return {
      runId: run.runId,
      traceId: run.traceId,
      ...(run.stateSnapshotId === undefined ? {} : { stateSnapshotId: run.stateSnapshotId }),
      startedAt: run.startedAt,
      ...(run.endedAt === undefined ? {} : { endedAt: run.endedAt }),
      status: run.finalStatus,
      ...(run.intent === undefined ? {} : { intent: run.intent.intent }),
      modelCalls: run.modelCalls.length,
      toolCalls: run.toolCalls.length,
      policyDecisions: run.policyDecisions.length,
      plannerRuns: run.plannerRuns.length,
      tokenUsage: structuredClone(run.tokenUsage),
      estimatedCost: run.estimatedCost,
      ...(run.error === undefined ? {} : { errorCode: run.error.code }),
    };
  }

  async getTrace(authenticatedUserId: string, rawRunId: string): Promise<TraceView> {
    this.assertEnabled();
    const run = await this.ownedRun(authenticatedUserId, rawRunId);
    const snapshot = run.stateSnapshotId === undefined ? null : await this.snapshots.getById(run.stateSnapshotId);
    return this.traceBuilder.build(run, snapshot, await this.audits.listByRun(run.runId));
  }

  simulatePlanning(authenticatedUserId: string, rawRequest: unknown): PlanningResult {
    this.assertEnabled();
    const request = PlanningRequestSchema.parse(rawRequest);
    this.assertStateOwner(authenticatedUserId, request.state.userId);
    return this.planner.plan(request);
  }

  validatePlanning(authenticatedUserId: string, rawInput: unknown): PlanValidationResult {
    this.assertEnabled();
    const input = DebugValidationRequestSchema.parse(rawInput);
    this.assertStateOwner(authenticatedUserId, input.request.state.userId);
    const candidate: RawScheduleCandidate = {
      id: input.candidate.id,
      blocks: input.candidate.blocks,
      changedExistingBlocks: input.candidate.changedExistingBlocks,
      ...(input.candidate.scheduleChangeCost === undefined ? {} : {
        scheduleChangeCost: input.candidate.scheduleChangeCost,
      }),
    };
    return this.validator.validate(candidate, input.request);
  }

  async replay(authenticatedUserId: string, rawBundle: unknown): Promise<ReplayResult> {
    this.assertEnabled();
    const bundle = z.object({ request: AgentRequestSchema }).passthrough().parse(rawBundle);
    this.assertStateOwner(authenticatedUserId, bundle.request.context.userId);
    return this.agent.replay(rawBundle);
  }

  private async ownedRun(userId: string, rawRunId: string): Promise<AgentRunRecord> {
    const runId = UUIDSchema.parse(rawRunId);
    const run = await this.runs.getById(runId);
    if (!run || run.userId !== userId) throw new LampError({
      code: "AUTH_ERROR",
      message: "Debug run not found or owned by another user",
      safeMessage: "无法访问该 Agent Run。",
      statusCode: 403,
    });
    return run;
  }

  private assertEnabled(): void {
    if (!this.options.enabled || this.options.environment === "production") throw new LampError({
      code: "POLICY_DENIED",
      message: "Debug API is disabled",
      safeMessage: "Debug API 当前不可用。",
      statusCode: 403,
    });
  }

  private assertStateOwner(authenticatedUserId: string, stateUserId: string): void {
    if (authenticatedUserId !== stateUserId) throw new LampError({
      code: "AUTH_ERROR",
      message: "Debug request state belongs to another user",
      safeMessage: "调试状态的用户隔离校验失败。",
      statusCode: 403,
    });
  }
}

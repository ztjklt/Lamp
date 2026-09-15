import { z } from "zod";
import { AgentActionSchema, type AgentAction } from "../schemas/AgentAction.js";
import type { AgentContext } from "./AgentContext.js";
import { AgentRunContextSchema, type AgentRunContext } from "./AgentRunContext.js";
import type { AgentRun } from "./AgentRun.js";
import type { StateSnapshot } from "../state/StateSnapshot.js";
import type { ActivityReader, AgentRunReader, ToolExecutionContext } from "../tools/AgentTool.js";
import type { ToolExecutor } from "../tools/ToolExecutor.js";
import type { ToolRegistry } from "../tools/ToolRegistry.js";
import type { Clock } from "../../infrastructure/clock/Clock.js";
import type { IdGenerator } from "../../infrastructure/id/IdGenerator.js";
import { LampError, toLampError } from "../../errors/LampError.js";
import type { Logger } from "../../observability/Logger.js";
import type { LLMGateway } from "../../llm/LLMGateway.js";
import type { LLMMessage } from "../../llm/LLMRequest.js";
import type { ModelRouter } from "../../llm/ModelRouter.js";
import type { SchedulingEngine } from "../../planning/SchedulingEngine.js";
import type { ReplanningEngine } from "../../planning/ReplanningEngine.js";
import { ContextBuilder } from "../context/ContextBuilder.js";
import { PlanningPolicy } from "../policies/PlanningPolicy.js";
import type { MemoryRetriever } from "../../domain/repositories/MemoryRepositories.js";
import type { WorkingMemory } from "../memory/WorkingMemory.js";

export type AgentLoopPhase = "RECEIVE" | "UNDERSTAND" | "BUILD_STATE" | "DECIDE" | "PLAN" | "ACT" | "OBSERVE" | "VERIFY" | "FINISH" | "SAFE_ABORT";

export interface AgentLoopLimits {
  maxModelTurns: number;
  maxToolCalls: number;
  maxPlanningAttempts: number;
  maxRepairAttempts: number;
  maxRunDurationMs: number;
}

export interface AgentLoopInput {
  userInput: string;
  agent: AgentContext;
  state: Readonly<StateSnapshot>;
  run: AgentRun;
  activityReader: ActivityReader;
  agentRunReader: AgentRunReader;
  limits: AgentLoopLimits;
  checkpoint: () => Promise<void>;
}

export interface AgentLoopOutcome {
  status: "succeeded" | "confirmation_required";
  message: string;
  proposal?: Record<string, unknown>;
  pendingActionId?: string;
}

export interface AgentLoopRuntime {
  clock: Clock;
  ids: IdGenerator;
  monotonicNow?: () => number;
}

export class AgentLoop {
  private readonly monotonicNow: () => number;

  constructor(
    private readonly llm: LLMGateway,
    private readonly tools: ToolRegistry,
    private readonly toolExecutor: ToolExecutor,
    private readonly planner: SchedulingEngine,
    private readonly modelRouter: ModelRouter,
    private readonly logger: Logger,
    private readonly runtime: AgentLoopRuntime,
    private readonly replanner?: ReplanningEngine,
    private readonly contextBuilder = new ContextBuilder(),
    private readonly planningPolicy = new PlanningPolicy(),
    private readonly memoryRetriever?: MemoryRetriever,
    private readonly workingMemory?: WorkingMemory,
  ) {
    this.monotonicNow = runtime.monotonicNow ?? performance.now.bind(performance);
  }

  async run(input: AgentLoopInput): Promise<AgentLoopOutcome> {
    const started = this.monotonicNow();
    let counters = this.context(input, 0, 0, 0, 0);
    let toolFailureCount = 0;
    let pendingProposal: Record<string, unknown> | undefined;
    const relevantMemories = this.memoryRetriever
      ? await this.memoryRetriever.retrieve({ userId: input.agent.userId, limit: 10 })
      : [];
    const workingMemory = this.workingMemory
      ? await this.workingMemory.listForRun(input.agent.userId, input.agent.sessionId, input.run.id)
      : [];
    const messages = this.contextBuilder.build(
      input.userInput,
      input.agent,
      input.state,
      relevantMemories,
      workingMemory,
    );
    this.phase("RECEIVE", input.run);
    this.phase("UNDERSTAND", input.run);
    this.phase("BUILD_STATE", input.run);

    for (let iteration = 0; iteration < input.limits.maxModelTurns; iteration += 1) {
      this.assertWithinDuration(started, input.limits.maxRunDurationMs);
      this.phase("DECIDE", input.run);
      const route = this.modelRouter.route({
        userInput: input.userInput,
        state: input.state,
        toolFailureCount,
        repairAttempts: counters.repairAttempts,
      });
      const modelCallId = this.runtime.ids.next();
      const modelStartedAt = this.runtime.clock.now().toString();
      counters = this.context(input, counters.modelTurns + 1, counters.toolCalls, counters.planningAttempts, counters.repairAttempts);
      const requestMessages = this.contextBuilder.compactMessages(messages);
      messages.splice(0, messages.length, ...requestMessages);
      let response;
      try {
        response = await this.llm.generate({
          model: route.model,
          messages: requestMessages,
          tools: this.toolDefinitions(),
          toolChoice: "auto",
          responseFormat: "json_object",
          thinking: route.thinking,
          temperature: 0,
          maxOutputTokens: 4_096,
          metadata: { runId: input.run.id, traceId: input.run.traceId, complexity: route.complexity },
        }, { traceId: input.run.traceId, runId: input.run.id });
        input.run.addModelCall({
          id: modelCallId,
          provider: response.provider,
          model: response.model,
          startedAt: modelStartedAt,
          endedAt: this.runtime.clock.now().toString(),
          status: "succeeded",
          inputTokens: response.usage.inputTokens,
          outputTokens: response.usage.outputTokens,
          cacheHitTokens: response.usage.cacheHitTokens,
          cacheMissTokens: response.usage.cacheMissTokens,
          latencyMs: response.latencyMs,
        });
      } catch (error) {
        const lampError = toLampError(error);
        input.run.addModelCall({
          id: modelCallId,
          provider: "llm_gateway",
          model: route.model,
          startedAt: modelStartedAt,
          endedAt: this.runtime.clock.now().toString(),
          status: "failed",
          errorCode: lampError.code,
        });
        await input.checkpoint();
        if (lampError.retryable && iteration + 1 < input.limits.maxModelTurns) continue;
        throw lampError;
      }
      await input.checkpoint();
      this.assertWithinDuration(started, input.limits.maxRunDurationMs);

      if (response.toolCalls.length > 0) {
        this.phase("ACT", input.run);
        if (counters.toolCalls + response.toolCalls.length > input.limits.maxToolCalls) {
          throw limitError("Tool call limit exceeded");
        }
        messages.push({
          role: "assistant",
          content: response.content,
          toolCalls: response.toolCalls,
          ...(response.reasoningContent === undefined ? {} : { reasoningContent: response.reasoningContent }),
        });
        for (const modelCall of response.toolCalls) {
          const registered = this.tools.get(modelCall.name);
          const executionContext: ToolExecutionContext = {
            agent: input.agent,
            runId: input.run.id,
            traceId: input.run.traceId,
            state: input.state,
            activityReader: input.activityReader,
            agentRunReader: input.agentRunReader,
            run: input.run,
          };
          const result = await this.toolExecutor.execute({
            id: this.runtime.ids.next(),
            name: modelCall.name,
            version: registered?.version ?? 1,
            arguments: modelCall.arguments,
          }, executionContext);
          counters = this.context(input, counters.modelTurns, counters.toolCalls + 1, counters.planningAttempts, counters.repairAttempts);
          this.assertWithinDuration(started, input.limits.maxRunDurationMs);
          await input.checkpoint();
          this.phase("OBSERVE", input.run);
          messages.push({
            role: "tool",
            name: modelCall.name,
            toolCallId: modelCall.id,
            content: this.contextBuilder.clipObservation(result),
          });
          if (result.status === "confirmation_required") {
            this.phase("FINISH", input.run);
            return {
              status: "confirmation_required",
              message: "此操作需要你的确认后才能执行。",
              pendingActionId: result.callId,
            };
          }
          if (result.status === "failed" || result.status === "denied") toolFailureCount += 1;
        }
        continue;
      }

      const action = this.parseAction(response.content);
      if (action === null) {
        counters = this.context(input, counters.modelTurns, counters.toolCalls, counters.planningAttempts, counters.repairAttempts + 1);
        if (counters.repairAttempts > input.limits.maxRepairAttempts) {
          throw new LampError({
            code: "MODEL_INVALID_OUTPUT",
            message: "Model output could not be repaired within the configured limit",
            safeMessage: "模型未能生成可验证的操作。",
            retryable: false,
          });
        }
        messages.push({ role: "assistant", content: this.contextBuilder.clipObservation(response.content) });
        messages.push({ role: "system", content: "REPAIR_REQUIRED: Return exactly one valid AgentAction JSON object. Do not add markdown." });
        continue;
      }

      input.run.setIntent(action.intent);
      input.run.addDecision(action.decision);
      await this.workingMemory?.put({
        userId: input.agent.userId,
        sessionId: input.agent.sessionId,
        runId: input.run.id,
        key: "latest_decision",
        value: {
          actionType: action.type,
          intent: action.intent.intent,
          goal: action.decision.goal,
          decisionAction: action.decision.action,
        },
        ttlMinutes: 120,
      });
      await input.checkpoint();
      if (action.type === "ask_user") {
        this.phase("FINISH", input.run);
        return { status: "confirmation_required", message: action.message };
      }
      if (action.type === "respond") {
        this.phase("VERIFY", input.run);
        this.phase("FINISH", input.run);
        return {
          status: "succeeded",
          message: action.message,
          ...(pendingProposal === undefined ? {} : { proposal: pendingProposal }),
        };
      }

      this.phase("PLAN", input.run);
      if (counters.planningAttempts >= input.limits.maxPlanningAttempts) throw limitError("Planning attempt limit exceeded");
      const policy = this.planningPolicy.evaluate(action, input.state);
      input.run.addPolicyDecision({
        policyId: policy.policyId,
        decision: policy.decision,
        reasonCode: policy.reasonCode,
        occurredAt: this.runtime.clock.now().toString(),
      });
      await input.checkpoint();
      if (policy.decision === "ask_user") {
        this.phase("FINISH", input.run);
        return { status: "confirmation_required", message: "规划条件仍有歧义，请补充时间范围或任务。" };
      }
      if (policy.decision === "deny") {
        throw new LampError({ code: "POLICY_DENIED", message: policy.reasonCode, safeMessage: "该规划请求未通过安全策略。", statusCode: 403 });
      }

      const plannerRunId = this.runtime.ids.next();
      const plannerStartedAt = this.runtime.clock.now().toString();
      if (action.intent.intent === "replan_schedule") {
        if (this.replanner === undefined) {
          throw new LampError({
            code: "INTERNAL_ERROR",
            message: "ReplanningEngine is not configured for replan_schedule",
            safeMessage: "重规划服务尚未配置。",
          });
        }
        const replanningResult = await this.replanner.replan({
          event: {
            eventId: this.runtime.ids.next(),
            userId: input.state.userId,
            occurredAt: this.runtime.clock.now().toString(),
            type: "USER_REQUEST_REPLAN",
            payload: { scope: action.planning.scope, taskIds: action.planning.taskIds },
          },
          state: input.state,
          candidateLimit: action.planning.candidateLimit,
          slotGranularityMinutes: action.planning.slotGranularityMinutes,
          maximumDailyFocusMinutes: action.planning.maximumDailyFocusMinutes,
        });
        this.assertWithinDuration(started, input.limits.maxRunDurationMs);
        counters = this.context(input, counters.modelTurns, counters.toolCalls, counters.planningAttempts + 1, counters.repairAttempts);
        input.run.addPlannerRun({
          id: plannerRunId,
          startedAt: plannerStartedAt,
          endedAt: this.runtime.clock.now().toString(),
          status: replanningResult.status === "proposal" || replanningResult.status === "no_replan"
            ? "success" : "no_feasible_plan",
          candidateCount: replanningResult.status === "proposal" ? 1 : 0,
          diagnostics: replanningResult.diagnostics,
        });
        await input.checkpoint();
        messages.push({ role: "assistant", content: JSON.stringify(action) });
        messages.push({
          role: "system",
          content: `REPLANNING_RESULT\n${this.contextBuilder.clipObservation(replanningResult)}`,
        });
        if (replanningResult.status === "proposal") {
          pendingProposal = {
            stateSnapshotId: input.state.snapshotId,
            baseStateRevision: input.state.sourceRevision,
            revision: replanningResult.revision,
            candidate: replanningResult.candidate,
          };
        } else if (replanningResult.status === "no_replan") {
          pendingProposal = { noChangesRequired: true, decision: replanningResult.decision };
        } else if (counters.planningAttempts >= input.limits.maxPlanningAttempts) {
          throw new LampError({
            code: "NO_FEASIBLE_PLAN",
            message: "No feasible replan after maximum planning attempts",
            safeMessage: "当前约束下无法生成可行的重规划方案。",
          });
        }
        continue;
      }
      const planningResult = this.planner.plan({ state: input.state, ...action.planning });
      this.assertWithinDuration(started, input.limits.maxRunDurationMs);
      counters = this.context(input, counters.modelTurns, counters.toolCalls, counters.planningAttempts + 1, counters.repairAttempts);
      input.run.addPlannerRun({
        id: plannerRunId,
        startedAt: plannerStartedAt,
        endedAt: this.runtime.clock.now().toString(),
        status: planningResult.status,
        candidateCount: planningResult.candidates.length,
        diagnostics: planningResult.diagnostics.map((diagnostic) => diagnostic.code),
      });
      await input.checkpoint();
      messages.push({ role: "assistant", content: JSON.stringify(action) });
      messages.push({
        role: "system",
        content: `PLANNER_RESULT\n${this.contextBuilder.clipObservation(planningResult)}`,
      });
      if (planningResult.status === "success") {
        pendingProposal = {
          stateSnapshotId: input.state.snapshotId,
          baseStateRevision: input.state.sourceRevision,
          candidates: planningResult.candidates,
        };
      }
      else if (counters.planningAttempts >= input.limits.maxPlanningAttempts) {
        throw new LampError({
          code: "NO_FEASIBLE_PLAN",
          message: "No feasible plan after maximum planning attempts",
          safeMessage: "当前约束下无法生成可行计划。",
        });
      }
    }
    throw limitError("Model turn limit exceeded");
  }

  private context(
    input: AgentLoopInput,
    modelTurns: number,
    toolCalls: number,
    planningAttempts: number,
    repairAttempts: number,
  ): AgentRunContext {
    return AgentRunContextSchema.parse({
      runId: input.run.id,
      traceId: input.run.traceId,
      userId: input.agent.userId,
      sessionId: input.agent.sessionId,
      requestId: input.agent.requestId,
      stateSnapshotId: input.state.snapshotId,
      modelTurns,
      toolCalls,
      planningAttempts,
      repairAttempts,
      limits: input.limits,
    });
  }

  private parseAction(content: string | null): AgentAction | null {
    if (content === null) return null;
    try {
      const raw: unknown = JSON.parse(content);
      const result = AgentActionSchema.safeParse(raw);
      return result.success ? result.data : null;
    } catch {
      return null;
    }
  }

  private toolDefinitions() {
    return this.tools.list().map((tool) => ({
      name: tool.name,
      description: tool.description,
      inputSchema: z.toJSONSchema(tool.inputSchema) as Record<string, unknown>,
    }));
  }

  private assertWithinDuration(started: number, maximum: number): void {
    if (this.monotonicNow() - started > maximum) {
      throw new LampError({ code: "MODEL_TIMEOUT", message: "Agent run duration limit exceeded", safeMessage: "Agent 运行超时。", retryable: true });
    }
  }

  private phase(phase: AgentLoopPhase, run: AgentRun): void {
    this.logger.debug("AgentLoop", "phase_changed", {
      traceId: run.traceId,
      runId: run.id,
      data: { phase },
    });
  }
}

function limitError(message: string): LampError {
  return new LampError({
    code: "RATE_LIMIT",
    message,
    safeMessage: "Agent 已达到本次运行的安全限制。",
    retryable: false,
    statusCode: 429,
  });
}

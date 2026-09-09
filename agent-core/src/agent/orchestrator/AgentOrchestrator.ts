import { z } from "zod";
import { AgentContextSchema } from "./AgentContext.js";
import { AgentRun, type AgentRunRuntime } from "./AgentRun.js";
import type { AgentLoop, AgentLoopLimits, AgentLoopOutcome } from "./AgentLoop.js";
import { AgentResponseSchema, type AgentResponse } from "../schemas/AgentResponse.js";
import type { StateEngine } from "../state/StateEngine.js";
import type { ActivityReader, AgentRunReader } from "../tools/AgentTool.js";
import type { AgentRunRepository } from "../../domain/repositories/AgentRunRepository.js";
import { LampError, toLampError } from "../../errors/LampError.js";
import type { Logger } from "../../observability/Logger.js";

export const AgentRequestSchema = z.object({
  context: AgentContextSchema,
  input: z.string().trim().min(1).max(8_000),
  horizonDays: z.number().int().min(1).max(90).optional(),
}).strict();

export type AgentRequest = z.infer<typeof AgentRequestSchema>;

export class AgentOrchestrator {
  constructor(
    private readonly stateEngine: StateEngine,
    private readonly loop: AgentLoop,
    private readonly runs: AgentRunRepository,
    private readonly activityReader: ActivityReader,
    private readonly agentRunReader: AgentRunReader,
    private readonly runtime: AgentRunRuntime,
    private readonly limits: AgentLoopLimits,
    private readonly logger: Logger,
  ) {}

  async execute(rawRequest: unknown): Promise<AgentResponse> {
    const request = AgentRequestSchema.parse(rawRequest);
    const run = AgentRun.start({
      userId: request.context.userId,
      sessionId: request.context.sessionId,
      requestId: request.context.requestId,
      initialInput: request.input,
    }, this.runtime);
    this.logger.info("AgentOrchestrator", "agent_run_started", {
      traceId: run.traceId,
      runId: run.id,
      data: { userId: request.context.userId },
    });

    try {
      await this.runs.save(run.snapshot());
      const state = await this.stateEngine.buildSnapshot({
        userId: request.context.userId,
        ...(request.horizonDays === undefined ? {} : { horizonDays: request.horizonDays }),
      });
      if (state.timezone !== request.context.timezone) {
        throw new LampError({
          code: "AUTH_ERROR",
          message: "Request timezone does not match authenticated user state",
          safeMessage: "请求上下文与当前用户状态不一致。",
          statusCode: 403,
        });
      }
      run.setStateSnapshot(state.snapshotId);
      await this.runs.save(run.snapshot());
      const outcome = await this.loop.run({
        userInput: request.input,
        agent: request.context,
        state,
        run,
        activityReader: this.activityReader,
        agentRunReader: this.agentRunReader,
        limits: this.limits,
        checkpoint: async () => this.runs.save(run.snapshot()),
      });
      this.finishRun(run, outcome);
      await this.runs.save(run.snapshot());
      this.logger.info("AgentOrchestrator", "agent_run_finished", {
        traceId: run.traceId,
        runId: run.id,
        data: { status: outcome.status },
      });
      return AgentResponseSchema.parse({
        runId: run.id,
        status: outcome.status,
        message: outcome.message,
        ...(outcome.proposal === undefined ? {} : { proposal: outcome.proposal }),
        ...(outcome.pendingActionId === undefined ? {} : { pendingActionId: outcome.pendingActionId }),
      });
    } catch (error) {
      const lampError = toLampError(error);
      const status = lampError.code === "INTERNAL_ERROR" || lampError.code === "DATABASE_ERROR" ? "failed" : "safe_aborted";
      if (run.snapshot().finalStatus === "running") {
        if (status === "failed") run.fail(lampError);
        else run.safeAbort(lampError);
        try {
          await this.runs.save(run.snapshot());
        } catch {
          // The response remains failed/safe-aborted; never claim success after persistence failure.
        }
      }
      this.logger.error("AgentOrchestrator", "agent_run_failed", {
        traceId: run.traceId,
        runId: run.id,
        data: { status, code: lampError.code, retryable: lampError.retryable },
      });
      return AgentResponseSchema.parse({
        runId: run.id,
        status,
        message: lampError.safeMessage,
        error: { code: lampError.code, message: lampError.safeMessage, retryable: lampError.retryable },
      });
    }
  }

  private finishRun(run: AgentRun, outcome: AgentLoopOutcome): void {
    const output = {
      message: outcome.message,
      ...(outcome.proposal === undefined ? {} : { proposal: outcome.proposal }),
      ...(outcome.pendingActionId === undefined ? {} : { pendingActionId: outcome.pendingActionId }),
    };
    if (outcome.status === "confirmation_required") run.requireConfirmation(output);
    else run.succeed(output);
  }
}

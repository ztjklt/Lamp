import { LampError } from "../../errors/LampError.js";
import {
  AgentRunRecordSchema,
  type AgentRunRecord,
  type ModelCallRecord,
  type PlannerRunRecord,
  type PolicyDecisionRecord,
} from "../schemas/AgentRun.js";
import type { Intent } from "../schemas/Intent.js";
import type { AgentDecision } from "../schemas/AgentDecision.js";
import type { JsonObject } from "../schemas/Common.js";
import type { ToolCallRecord } from "../schemas/ToolCall.js";
import type { Clock } from "../../infrastructure/clock/Clock.js";
import type { IdGenerator } from "../../infrastructure/id/IdGenerator.js";

export interface AgentRunRuntime {
  clock: Clock;
  ids: IdGenerator;
}

export interface StartAgentRunInput {
  userId: string;
  sessionId: string;
  requestId: string;
  initialInput: string;
  traceId?: string;
}

export class AgentRun {
  private record: AgentRunRecord;

  private constructor(
    record: AgentRunRecord,
    private readonly runtime: AgentRunRuntime,
  ) {
    this.record = record;
  }

  static start(input: StartAgentRunInput, runtime: AgentRunRuntime): AgentRun {
    const record = AgentRunRecordSchema.parse({
      runId: runtime.ids.next(),
      traceId: input.traceId ?? runtime.ids.next(),
      userId: input.userId,
      sessionId: input.sessionId,
      requestId: input.requestId,
      startedAt: runtime.clock.now().toString(),
      initialInput: input.initialInput,
      decisions: [],
      modelCalls: [],
      toolCalls: [],
      policyDecisions: [],
      plannerRuns: [],
      traceSteps: [],
      finalStatus: "running",
      tokenUsage: { input: 0, output: 0, cacheHit: 0, cacheMiss: 0 },
      estimatedCost: 0,
    });
    return new AgentRun(record, runtime);
  }

  get id(): string {
    return this.record.runId;
  }

  get traceId(): string {
    return this.record.traceId;
  }

  setIntent(intent: Intent): void {
    this.ensureRunning();
    this.replace({ intent });
  }

  setStateSnapshot(stateSnapshotId: string): void {
    this.ensureRunning();
    this.replace({
      stateSnapshotId,
      traceSteps: this.nextTrace("StateBuilt", this.runtime.clock.now().toString(), stateSnapshotId),
    });
  }

  addDecision(decision: AgentDecision): void {
    this.ensureRunning();
    this.replace({ decisions: [...this.record.decisions, decision] });
  }

  addModelCall(call: ModelCallRecord): void {
    this.ensureRunning();
    this.replace({
      modelCalls: [...this.record.modelCalls, call],
      tokenUsage: {
        input: this.record.tokenUsage.input + (call.inputTokens ?? 0),
        output: this.record.tokenUsage.output + (call.outputTokens ?? 0),
        cacheHit: this.record.tokenUsage.cacheHit + (call.cacheHitTokens ?? 0),
        cacheMiss: this.record.tokenUsage.cacheMiss + (call.cacheMissTokens ?? 0),
      },
      estimatedCost: this.record.estimatedCost + (call.estimatedCost ?? 0),
      traceSteps: this.nextTrace("LLMCall", call.endedAt ?? call.startedAt, call.id),
    });
  }

  addToolCall(call: ToolCallRecord): void {
    this.ensureRunning();
    this.replace({
      toolCalls: [...this.record.toolCalls, call],
      traceSteps: this.nextTrace("ToolExecuted", call.endedAt ?? call.startedAt, call.call.id),
    });
  }

  addToolSelection(callId: string, occurredAt: string): void {
    this.ensureRunning();
    this.replace({ traceSteps: this.nextTrace("ToolSelected", occurredAt, callId) });
  }

  addPolicyDecision(decision: PolicyDecisionRecord): void {
    this.ensureRunning();
    this.replace({
      policyDecisions: [...this.record.policyDecisions, decision],
      traceSteps: this.nextTrace("PolicyChecked", decision.occurredAt, `policy:${this.record.policyDecisions.length}`),
    });
  }

  addPlannerRun(plannerRun: PlannerRunRecord): void {
    this.ensureRunning();
    this.replace({
      plannerRuns: [...this.record.plannerRuns, plannerRun],
      traceSteps: this.nextTrace("PlanValidated", plannerRun.endedAt ?? plannerRun.startedAt, plannerRun.id),
    });
  }

  succeed(finalOutput: JsonObject): void {
    this.finish("succeeded", finalOutput);
  }

  requireConfirmation(finalOutput: JsonObject): void {
    this.finish("confirmation_required", finalOutput);
  }

  safeAbort(error: LampError): void {
    this.finishWithError("safe_aborted", error);
  }

  fail(error: LampError): void {
    this.finishWithError("failed", error);
  }

  snapshot(): Readonly<AgentRunRecord> {
    return structuredClone(this.record);
  }

  private finish(status: "succeeded" | "confirmation_required", finalOutput: JsonObject): void {
    this.ensureRunning();
    const endedAt = this.runtime.clock.now().toString();
    this.replace({
      finalStatus: status,
      finalOutput,
      endedAt,
      traceSteps: this.nextTrace("AgentFinished", endedAt),
    });
  }

  private finishWithError(status: "safe_aborted" | "failed", error: LampError): void {
    this.ensureRunning();
    const endedAt = this.runtime.clock.now().toString();
    this.replace({
      finalStatus: status,
      endedAt,
      error: { code: error.code, message: error.message, retryable: error.retryable },
      traceSteps: this.nextTrace("AgentFinished", endedAt),
    });
  }

  private nextTrace(
    type: AgentRunRecord["traceSteps"][number]["type"],
    occurredAt: string,
    referenceId?: string,
  ): AgentRunRecord["traceSteps"] {
    return [...this.record.traceSteps, {
      sequence: this.record.traceSteps.length + 1,
      type,
      occurredAt,
      ...(referenceId === undefined ? {} : { referenceId }),
    }];
  }

  private ensureRunning(): void {
    if (this.record.finalStatus !== "running") {
      throw new LampError({
        code: "CONFLICT_ERROR",
        message: `Agent run ${this.record.runId} is already ${this.record.finalStatus}`,
        safeMessage: "该 Agent Run 已结束，不能继续写入。",
        statusCode: 409,
      });
    }
  }

  private replace(patch: Partial<AgentRunRecord>): void {
    this.record = AgentRunRecordSchema.parse({ ...this.record, ...patch });
  }
}

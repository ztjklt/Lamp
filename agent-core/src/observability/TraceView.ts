import { z } from "zod";
import { AgentRunRecordSchema, type AgentRunRecord } from "../agent/schemas/AgentRun.js";
import { JsonObjectSchema, TimestampSchema, UUIDSchema } from "../agent/schemas/Common.js";
import type { StateSnapshot } from "../agent/state/StateSnapshot.js";
import type { AuditRecord } from "./AuditLog.js";
import { LampError } from "../errors/LampError.js";

export const TRACE_EVENT_TYPES = [
  "AgentStart", "StateBuilt", "LLMCall", "ToolSelected", "PolicyChecked", "ToolExecuted",
  "PlannerStarted", "CandidateGenerated", "CandidateScored", "PlanValidated", "AgentFinished",
] as const;

export const TraceEventSchema = z.object({
  sequence: z.number().int().nonnegative(),
  occurredAt: TimestampSchema,
  type: z.enum(TRACE_EVENT_TYPES),
  status: z.string().min(1).optional(),
  reasonCode: z.string().min(1).optional(),
  data: JsonObjectSchema,
}).strict();

export const TraceViewSchema = z.object({
  traceId: UUIDSchema,
  runId: UUIDSchema,
  status: AgentRunRecordSchema.shape.finalStatus,
  intent: z.string().optional(),
  state: z.object({
    snapshotId: UUIDSchema,
    sourceRevision: z.number().int().nonnegative(),
    now: TimestampSchema,
    timezone: z.string().min(1),
    taskCount: z.number().int().nonnegative(),
    scheduleBlockCount: z.number().int().nonnegative(),
    calendarEventCount: z.number().int().nonnegative(),
  }).strict().optional(),
  totals: z.object({
    modelCalls: z.number().int().nonnegative(),
    toolCalls: z.number().int().nonnegative(),
    policyDecisions: z.number().int().nonnegative(),
    plannerRuns: z.number().int().nonnegative(),
    inputTokens: z.number().int().nonnegative(),
    outputTokens: z.number().int().nonnegative(),
    estimatedCost: z.number().nonnegative(),
  }).strict(),
  events: z.array(TraceEventSchema),
}).strict();

export type TraceEvent = z.infer<typeof TraceEventSchema>;
export type TraceView = z.infer<typeof TraceViewSchema>;

export class TraceViewBuilder {
  build(rawRun: AgentRunRecord, snapshot?: Readonly<StateSnapshot> | null, audits: readonly AuditRecord[] = []): TraceView {
    const run = AgentRunRecordSchema.parse(rawRun);
    if (snapshot && (snapshot.userId !== run.userId || snapshot.snapshotId !== run.stateSnapshotId)) {
      throw new LampError({
        code: "AUTH_ERROR",
        message: "Trace state snapshot does not belong to the run",
        safeMessage: "Trace 状态隔离校验失败。",
        statusCode: 403,
      });
    }
    const events: Array<Omit<TraceEvent, "sequence"> & { order: number }> = [];
    events.push({ occurredAt: run.startedAt, type: "AgentStart", status: "started", data: {}, order: 0 });
    if (snapshot) events.push({
      occurredAt: snapshot.capturedAt,
      type: "StateBuilt",
      status: "succeeded",
      data: { snapshotId: snapshot.snapshotId, sourceRevision: snapshot.sourceRevision },
      order: traceOrder(run, "StateBuilt", snapshot.snapshotId, 10),
    });
    for (const call of run.modelCalls) events.push({
      occurredAt: call.endedAt ?? call.startedAt,
      type: "LLMCall",
      status: call.status,
      ...(call.errorCode === undefined ? {} : { reasonCode: call.errorCode }),
      data: {
        provider: call.provider,
        model: call.model,
        inputTokens: call.inputTokens ?? 0,
        outputTokens: call.outputTokens ?? 0,
        latencyMs: call.latencyMs ?? 0,
      },
      order: traceOrder(run, "LLMCall", call.id, 20),
    });
    for (const call of run.toolCalls) {
      events.push({
        occurredAt: call.startedAt,
        type: "ToolSelected",
        status: "selected",
        data: { toolName: call.call.name, version: call.call.version, riskLevel: call.riskLevel },
        order: traceOrder(run, "ToolSelected", call.call.id, 30),
      });
      events.push({
        occurredAt: call.endedAt ?? call.startedAt,
        type: "ToolExecuted",
        status: call.status,
        ...(call.errorCode === undefined ? {} : { reasonCode: call.errorCode }),
        data: { toolName: call.call.name, audited: audits.some((audit) => audit.callId === call.call.id) },
        order: traceOrder(run, "ToolExecuted", call.call.id, 50),
      });
    }
    for (const [index, decision] of run.policyDecisions.entries()) events.push({
      occurredAt: decision.occurredAt,
      type: "PolicyChecked",
      status: decision.decision,
      reasonCode: decision.reasonCode,
      data: { policyId: decision.policyId },
      order: traceOrder(run, "PolicyChecked", `policy:${index}`, 40),
    });
    for (const planner of run.plannerRuns) {
      events.push({
        occurredAt: planner.startedAt,
        type: "PlannerStarted",
        status: "started",
        data: { plannerRunId: planner.id },
        order: traceOrder(run, "PlanValidated", planner.id, 60) - 3,
      });
      if (planner.candidateCount !== undefined) {
        events.push({
          occurredAt: planner.endedAt ?? planner.startedAt,
          type: "CandidateGenerated",
          status: planner.status,
          data: { candidateCount: planner.candidateCount },
          order: traceOrder(run, "PlanValidated", planner.id, 70) - 2,
        });
        events.push({
          occurredAt: planner.endedAt ?? planner.startedAt,
          type: "CandidateScored",
          status: planner.status,
          data: { candidateCount: planner.candidateCount },
          order: traceOrder(run, "PlanValidated", planner.id, 80) - 1,
        });
      }
      events.push({
        occurredAt: planner.endedAt ?? planner.startedAt,
        type: "PlanValidated",
        status: planner.status,
        data: { diagnostics: planner.diagnostics ?? [] },
        order: traceOrder(run, "PlanValidated", planner.id, 90),
      });
    }
    if (run.finalStatus !== "running") events.push({
      occurredAt: run.endedAt ?? run.startedAt,
      type: "AgentFinished",
      status: run.finalStatus,
      ...(run.error === undefined ? {} : { reasonCode: run.error.code }),
      data: {},
      order: traceOrder(run, "AgentFinished", undefined, 100),
    });
    events.sort((left, right) => left.order - right.order || left.occurredAt.localeCompare(right.occurredAt));
    return TraceViewSchema.parse({
      traceId: run.traceId,
      runId: run.runId,
      status: run.finalStatus,
      ...(run.intent === undefined ? {} : { intent: run.intent.intent }),
      ...(snapshot === null || snapshot === undefined ? {} : {
        state: {
          snapshotId: snapshot.snapshotId,
          sourceRevision: snapshot.sourceRevision,
          now: snapshot.now,
          timezone: snapshot.timezone,
          taskCount: snapshot.activeTasks.length,
          scheduleBlockCount: snapshot.schedule.length,
          calendarEventCount: snapshot.upcomingEvents.length,
        },
      }),
      totals: {
        modelCalls: run.modelCalls.length,
        toolCalls: run.toolCalls.length,
        policyDecisions: run.policyDecisions.length,
        plannerRuns: run.plannerRuns.length,
        inputTokens: run.tokenUsage.input,
        outputTokens: run.tokenUsage.output,
        estimatedCost: run.estimatedCost,
      },
      events: events.map(({ order: _order, ...event }, sequence) => ({ ...event, sequence })),
    });
  }
}

function traceOrder(
  run: AgentRunRecord,
  type: AgentRunRecord["traceSteps"][number]["type"],
  referenceId: string | undefined,
  fallback: number,
): number {
  const step = run.traceSteps.find((item) => item.type === type &&
    (referenceId === undefined || item.referenceId === referenceId));
  return step === undefined ? fallback : step.sequence * 10;
}

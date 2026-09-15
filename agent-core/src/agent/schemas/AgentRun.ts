import { z } from "zod";
import { ERROR_CODES } from "../../errors/ErrorCode.js";
import { IntentSchema } from "./Intent.js";
import { JsonObjectSchema, TimestampSchema, UUIDSchema } from "./Common.js";
import { ToolCallRecordSchema } from "./ToolCall.js";
import { AgentDecisionSchema } from "./AgentDecision.js";

export const AgentRunStatusSchema = z.enum([
  "running",
  "succeeded",
  "confirmation_required",
  "safe_aborted",
  "failed",
]);

export const ModelCallRecordSchema = z.object({
  id: UUIDSchema,
  provider: z.string().min(1),
  model: z.string().min(1),
  startedAt: TimestampSchema,
  endedAt: TimestampSchema.optional(),
  status: z.enum(["requested", "succeeded", "failed"]),
  inputTokens: z.number().int().nonnegative().optional(),
  outputTokens: z.number().int().nonnegative().optional(),
  cacheHitTokens: z.number().int().nonnegative().optional(),
  cacheMissTokens: z.number().int().nonnegative().optional(),
  latencyMs: z.number().int().nonnegative().optional(),
  estimatedCost: z.number().nonnegative().optional(),
  errorCode: z.enum(ERROR_CODES).optional(),
}).strict();

export const PolicyDecisionRecordSchema = z.object({
  policyId: z.string().min(1),
  decision: z.enum(["allow", "ask_user", "deny"]),
  reasonCode: z.string().min(1),
  occurredAt: TimestampSchema,
}).strict();

export const PlannerRunRecordSchema = z.object({
  id: UUIDSchema,
  startedAt: TimestampSchema,
  endedAt: TimestampSchema.optional(),
  status: z.enum(["running", "success", "no_feasible_plan", "failed"]),
  candidateCount: z.number().int().nonnegative().optional(),
  diagnostics: z.array(z.string()).optional(),
}).strict();

export const AgentTraceStepSchema = z.object({
  sequence: z.number().int().positive(),
  type: z.enum(["StateBuilt", "LLMCall", "ToolSelected", "ToolExecuted", "PolicyChecked", "PlanValidated", "AgentFinished"]),
  occurredAt: TimestampSchema,
  referenceId: z.string().min(1).optional(),
}).strict();

export const AgentRunRecordSchema = z.object({
  runId: UUIDSchema,
  traceId: UUIDSchema,
  userId: z.string().min(1),
  sessionId: z.string().min(1),
  requestId: z.string().min(1),
  startedAt: TimestampSchema,
  endedAt: TimestampSchema.optional(),
  initialInput: z.string().min(1).max(8_000),
  intent: IntentSchema.optional(),
  decisions: z.array(AgentDecisionSchema),
  stateSnapshotId: UUIDSchema.optional(),
  modelCalls: z.array(ModelCallRecordSchema),
  toolCalls: z.array(ToolCallRecordSchema),
  policyDecisions: z.array(PolicyDecisionRecordSchema),
  plannerRuns: z.array(PlannerRunRecordSchema),
  traceSteps: z.array(AgentTraceStepSchema).default([]),
  finalStatus: AgentRunStatusSchema,
  finalOutput: JsonObjectSchema.optional(),
  error: z.object({
    code: z.enum(ERROR_CODES),
    message: z.string(),
    retryable: z.boolean(),
  }).strict().optional(),
  tokenUsage: z.object({
    input: z.number().int().nonnegative(),
    output: z.number().int().nonnegative(),
    cacheHit: z.number().int().nonnegative(),
    cacheMiss: z.number().int().nonnegative(),
  }).strict(),
  estimatedCost: z.number().nonnegative(),
}).strict();

export type AgentRunStatus = z.infer<typeof AgentRunStatusSchema>;
export type AgentRunRecord = z.infer<typeof AgentRunRecordSchema>;
export type ModelCallRecord = z.infer<typeof ModelCallRecordSchema>;
export type PolicyDecisionRecord = z.infer<typeof PolicyDecisionRecordSchema>;
export type PlannerRunRecord = z.infer<typeof PlannerRunRecordSchema>;
export type AgentTraceStep = z.infer<typeof AgentTraceStepSchema>;

import { z } from "zod";
import { TimeRangeSchema, UTCInstantSchema } from "../agent/state/StateModels.js";
import { PlanChangeSchema, ReplanningScopeSchema } from "../planning/ReplanningTypes.js";
import { ProposedScheduleBlockSchema } from "../planning/PlanningTypes.js";
import { ClientScheduleBlockSchema, ClientTaskSchema } from "./PlanDayContract.js";

const PreferencesSchema = z.object({
  preferredSleepTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).nullable().default(null),
  preferredWakeTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).nullable().default(null),
  preferredFocusMinutes: z.number().int().min(15).max(180),
  preferredBreakMinutes: z.number().int().min(0).max(120),
  morningStudyPreference: z.number().min(0).max(1),
  eveningStudyPreference: z.number().min(0).max(1),
}).strict();

export const LanguageReplanRequestSchema = z.object({
  schemaVersion: z.literal(1),
  requestId: z.uuid(),
  sourceFingerprint: z.string().regex(/^[a-f0-9]{64}$/),
  requestedAt: UTCInstantSchema,
  timezone: z.string().min(1).max(80),
  locale: z.string().min(1).max(40),
  input: z.string().trim().min(1).max(4_000),
  planningHorizon: TimeRangeSchema,
  tasks: z.array(ClientTaskSchema).min(1).max(100),
  schedule: z.array(ClientScheduleBlockSchema).max(500),
  preferences: PreferencesSchema,
}).strict().superRefine((request, context) => {
  const taskIds = new Set(request.tasks.map((task) => task.id));
  if (taskIds.size !== request.tasks.length) {
    context.addIssue({ code: "custom", path: ["tasks"], message: "task ids must be unique" });
  }
  if (new Set(request.schedule.map((block) => block.id)).size !== request.schedule.length) {
    context.addIssue({ code: "custom", path: ["schedule"], message: "schedule block ids must be unique" });
  }
  if (request.schedule.some((block) => block.taskId !== null && !taskIds.has(block.taskId))) {
    context.addIssue({ code: "custom", path: ["schedule"], message: "schedule task ids must exist in tasks" });
  }
  const start = Date.parse(request.planningHorizon.start);
  const end = Date.parse(request.planningHorizon.end);
  const requestedAt = Date.parse(request.requestedAt);
  if (requestedAt < start || requestedAt >= end || end - start > 26 * 60 * 60_000) {
    context.addIssue({ code: "custom", path: ["planningHorizon"], message: "request must be inside a horizon of at most 26 hours" });
  }
  if (request.schedule.some((block) => Date.parse(block.startsAt) >= end || Date.parse(block.endsAt) <= start)) {
    context.addIssue({ code: "custom", path: ["schedule"], message: "schedule blocks must intersect the planning horizon" });
  }
});

export const LanguageWorkloadDecisionSchema = z.object({
  intent: z.literal("replan_schedule"),
  action: z.literal("reduce_task_workload"),
  taskId: z.uuid(),
  targetMinutes: z.number().int().min(1).max(480),
  scope: z.enum(["local", "day"]),
  temporaryState: z.literal("tired"),
  reasonCodes: z.array(z.string().regex(/^[A-Z][A-Z0-9_]*$/)).min(1).max(20),
  confidence: z.number().min(0).max(1),
}).strict();

const ProposalSchema = z.object({
  id: z.uuid(),
  sourceRequestId: z.uuid(),
  scope: ReplanningScopeSchema,
  title: z.string().min(1).max(120),
  summary: z.string().min(1).max(500),
  reason: z.string().min(1).max(500),
  blocks: z.array(ProposedScheduleBlockSchema).max(500),
  changes: z.array(PlanChangeSchema).max(500),
  warnings: z.array(z.string().min(1).max(500)).max(50),
}).strict();

const TraceSchema = z.object({
  traceId: z.uuid(),
  model: z.object({ provider: z.string().min(1), model: z.string().min(1) }).strict(),
  intent: z.literal("replan_schedule"),
  decision: LanguageWorkloadDecisionSchema,
  diagnostics: z.array(z.string().max(500)).max(50),
}).strict();

const ResponseBase = z.object({
  schemaVersion: z.literal(1),
  requestId: z.uuid(),
  sourceFingerprint: z.string().regex(/^[a-f0-9]{64}$/),
  commitRequired: z.literal(true),
});

export const LanguageReplanResponseSchema = z.discriminatedUnion("status", [
  ResponseBase.extend({ status: z.literal("proposal"), proposal: ProposalSchema, trace: TraceSchema }).strict(),
  ResponseBase.extend({
    status: z.literal("no_feasible_plan"), proposal: z.null(), trace: TraceSchema,
  }).strict(),
]);

export type LanguageReplanRequest = z.infer<typeof LanguageReplanRequestSchema>;
export type LanguageWorkloadDecision = z.infer<typeof LanguageWorkloadDecisionSchema>;
export type LanguageReplanResponse = z.infer<typeof LanguageReplanResponseSchema>;

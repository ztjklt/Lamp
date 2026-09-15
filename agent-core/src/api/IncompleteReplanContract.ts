import { z } from "zod";
import { UTCInstantSchema, TimeRangeSchema } from "../agent/state/StateModels.js";
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

export const IncompleteReplanRequestSchema = z.object({
  schemaVersion: z.literal(1),
  eventId: z.uuid(),
  sourceFingerprint: z.string().regex(/^[a-f0-9]{64}$/),
  occurredAt: UTCInstantSchema,
  timezone: z.string().min(1).max(80),
  locale: z.string().min(1).max(40),
  planningHorizon: TimeRangeSchema,
  taskId: z.uuid(),
  incompleteBlockId: z.uuid(),
  additionalMinutes: z.number().int().positive().max(480),
  tasks: z.array(ClientTaskSchema).min(1).max(100),
  schedule: z.array(ClientScheduleBlockSchema).max(500),
  preferences: PreferencesSchema,
}).strict().superRefine((request, context) => {
  const taskIds = new Set(request.tasks.map((task) => task.id));
  if (taskIds.size !== request.tasks.length) {
    context.addIssue({ code: "custom", path: ["tasks"], message: "task ids must be unique" });
  }
  if (!taskIds.has(request.taskId)) {
    context.addIssue({ code: "custom", path: ["taskId"], message: "incomplete task must exist in tasks" });
  }
  const incomplete = request.schedule.find((block) => block.id === request.incompleteBlockId);
  if (incomplete === undefined || incomplete.taskId !== request.taskId || incomplete.state !== "missed") {
    context.addIssue({ code: "custom", path: ["incompleteBlockId"], message: "incomplete block must be a missed block for the task" });
  }
  const start = Date.parse(request.planningHorizon.start);
  const end = Date.parse(request.planningHorizon.end);
  if (Date.parse(request.occurredAt) < start || Date.parse(request.occurredAt) >= end || end - start > 8 * 86_400_000) {
    context.addIssue({ code: "custom", path: ["planningHorizon"], message: "event must be inside a horizon of at most eight days" });
  }
  if (new Set(request.schedule.map((block) => block.id)).size !== request.schedule.length) {
    context.addIssue({ code: "custom", path: ["schedule"], message: "schedule block ids must be unique" });
  }
  if (request.schedule.some((block) => block.taskId !== null && !taskIds.has(block.taskId))) {
    context.addIssue({ code: "custom", path: ["schedule"], message: "schedule task ids must exist in tasks" });
  }
  if (request.schedule.some((block) => Date.parse(block.startsAt) >= end || Date.parse(block.endsAt) <= start)) {
    context.addIssue({ code: "custom", path: ["schedule"], message: "schedule blocks must intersect the planning horizon" });
  }
});

const IncompleteReplanProposalSchema = z.object({
  id: z.uuid(),
  sourceEventId: z.uuid(),
  scope: ReplanningScopeSchema,
  title: z.string().min(1).max(120),
  summary: z.string().min(1).max(500),
  reason: z.string().min(1).max(500),
  blocks: z.array(ProposedScheduleBlockSchema).max(500),
  changes: z.array(PlanChangeSchema).max(500),
  warnings: z.array(z.string().min(1).max(500)).max(50),
}).strict();

const ResponseBase = z.object({
  schemaVersion: z.literal(1),
  eventId: z.uuid(),
  sourceFingerprint: z.string().regex(/^[a-f0-9]{64}$/),
  commitRequired: z.literal(true),
});

export const IncompleteReplanResponseSchema = z.discriminatedUnion("status", [
  ResponseBase.extend({
    status: z.literal("proposal"),
    proposal: IncompleteReplanProposalSchema,
    diagnostics: z.array(z.string().max(500)).max(50),
  }).strict(),
  ResponseBase.extend({
    status: z.enum(["no_replan", "no_feasible_plan"]),
    proposal: z.null(),
    diagnostics: z.array(z.string().min(1).max(500)).min(1).max(50),
  }).strict(),
]);

export type IncompleteReplanRequest = z.infer<typeof IncompleteReplanRequestSchema>;
export type IncompleteReplanResponse = z.infer<typeof IncompleteReplanResponseSchema>;

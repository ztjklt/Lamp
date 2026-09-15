import { z } from "zod";
import { TimeRangeSchema, UTCInstantSchema } from "../agent/state/StateModels.js";
import { ProposedScheduleBlockSchema } from "../planning/PlanningTypes.js";

export const ClientTaskSchema = z.object({
  id: z.uuid(),
  goalId: z.uuid().nullable().default(null),
  title: z.string().min(1).max(240),
  detail: z.string().max(4_000),
  importance: z.number().int().min(1).max(5),
  deadline: UTCInstantSchema.nullable(),
  estimatedMinutes: z.number().int().nonnegative(),
  remainingMinutes: z.number().int().nonnegative(),
  isPaused: z.boolean(),
  isSplittable: z.boolean(),
  minimumSessionMinutes: z.number().int().positive(),
  maximumSessionMinutes: z.number().int().positive(),
  preferredPeriods: z.array(z.enum(["morning", "afternoon", "evening"])),
  dependencyIds: z.array(z.uuid()),
  availableWindows: z.array(TimeRangeSchema).default([]),
}).strict().refine(
  (task) => task.maximumSessionMinutes >= task.minimumSessionMinutes,
  "maximumSessionMinutes must be at least minimumSessionMinutes",
);

export const ClientScheduleBlockSchema = z.object({
  id: z.uuid(),
  taskId: z.uuid().nullable().default(null),
  title: z.string().min(1).max(240),
  startsAt: UTCInstantSchema,
  endsAt: UTCInstantSchema,
  kind: z.enum(["fixed", "focus", "break", "free"]),
  state: z.enum(["planned", "active", "completed", "partial", "missed", "cancelled"]),
  locked: z.boolean(),
  provenance: z.string().min(1).max(500),
}).strict().refine(
  (block) => Date.parse(block.endsAt) > Date.parse(block.startsAt),
  "schedule block must have positive duration",
);

export const PlanDayRequestSchema = z.object({
  schemaVersion: z.literal(1),
  requestId: z.uuid(),
  sourceFingerprint: z.string().regex(/^[a-f0-9]{64}$/),
  requestedAt: UTCInstantSchema,
  timezone: z.string().min(1).max(80),
  locale: z.string().min(1).max(40),
  horizon: TimeRangeSchema,
  focusMinutesBeforeHorizon: z.number().int().min(0).max(960).default(0),
  tasks: z.array(ClientTaskSchema).max(100),
  schedule: z.array(ClientScheduleBlockSchema).max(500),
  preferences: z.object({
    preferredSleepTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).nullable().default(null),
    preferredWakeTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).nullable().default(null),
    preferredFocusMinutes: z.number().int().min(15).max(180),
    preferredBreakMinutes: z.number().int().min(0).max(120),
    morningStudyPreference: z.number().min(0).max(1),
    eveningStudyPreference: z.number().min(0).max(1),
  }).strict(),
}).strict().superRefine((request, context) => {
  const start = Date.parse(request.horizon.start);
  const end = Date.parse(request.horizon.end);
  if (end - start > 26 * 60 * 60 * 1_000) {
    context.addIssue({ code: "custom", path: ["horizon"], message: "day planning horizon cannot exceed 26 hours" });
  }
  const taskIds = new Set(request.tasks.map((task) => task.id));
  if (taskIds.size !== request.tasks.length) {
    context.addIssue({ code: "custom", path: ["tasks"], message: "task ids must be unique" });
  }
  for (const block of request.schedule) {
    if (Date.parse(block.startsAt) >= end || Date.parse(block.endsAt) <= start) {
      context.addIssue({ code: "custom", path: ["schedule"], message: "schedule blocks must intersect the requested horizon" });
      break;
    }
    if (block.taskId !== null && !taskIds.has(block.taskId)) {
      context.addIssue({ code: "custom", path: ["schedule"], message: "schedule task ids must exist in tasks" });
      break;
    }
  }
});

export const PlanDayProposalSchema = z.object({
  id: z.uuid(),
  candidateId: z.uuid(),
  title: z.string().min(1).max(120),
  summary: z.string().min(1).max(500),
  reason: z.string().min(1).max(500),
  blocks: z.array(ProposedScheduleBlockSchema).max(500),
  warnings: z.array(z.string().min(1).max(500)).max(50),
}).strict();

const PlanDayResponseBaseSchema = z.object({
  schemaVersion: z.literal(1),
  requestId: z.uuid(),
  sourceFingerprint: z.string().regex(/^[a-f0-9]{64}$/),
  commitRequired: z.literal(true),
});

export const PlanDayResponseSchema = z.discriminatedUnion("status", [
  PlanDayResponseBaseSchema.extend({
    status: z.literal("proposal"),
    proposal: PlanDayProposalSchema,
    diagnostics: z.array(z.string().min(1).max(500)).max(50),
  }).strict(),
  PlanDayResponseBaseSchema.extend({
    status: z.literal("no_feasible_plan"),
    proposal: z.null(),
    diagnostics: z.array(z.string().min(1).max(500)).min(1).max(50),
  }).strict(),
]).superRefine((response, context) => {
  if (response.status === "proposal" && response.proposal.blocks.length === 0) {
    context.addIssue({ code: "custom", path: ["proposal", "blocks"], message: "proposal must contain at least one block" });
  }
});

export type PlanDayRequest = z.infer<typeof PlanDayRequestSchema>;
export type PlanDayResponse = z.infer<typeof PlanDayResponseSchema>;

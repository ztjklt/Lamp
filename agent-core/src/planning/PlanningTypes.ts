import { z } from "zod";
import { TimeRangeSchema, UTCInstantSchema } from "../agent/state/StateModels.js";
import { StateSnapshotSchema } from "../agent/state/StateSnapshot.js";

export const PLANNING_SCOPES = ["local", "day", "multi_day", "full"] as const;

export const PlanningRequestSchema = z.object({
  state: StateSnapshotSchema,
  taskIds: z.array(z.uuid()).min(1).max(100),
  horizon: TimeRangeSchema,
  scope: z.enum(PLANNING_SCOPES),
  candidateLimit: z.number().int().min(1).max(10).default(3),
  slotGranularityMinutes: z.union([
    z.literal(5),
    z.literal(10),
    z.literal(15),
    z.literal(30),
    z.literal(60),
  ]).default(30),
  maximumDailyFocusMinutes: z.number().int().min(30).max(960).default(360),
}).strict().superRefine((request, context) => {
  if (Date.parse(request.horizon.start) < Date.parse(request.state.planningHorizon.start) ||
      Date.parse(request.horizon.end) > Date.parse(request.state.planningHorizon.end)) {
    context.addIssue({
      code: "custom",
      path: ["horizon"],
      message: "planning horizon must be contained in the state snapshot",
    });
  }
  if (new Set(request.taskIds).size !== request.taskIds.length) {
    context.addIssue({ code: "custom", path: ["taskIds"], message: "taskIds must be unique" });
  }
});

export const ProposedScheduleBlockSchema = z.object({
  id: z.uuid(),
  taskId: z.uuid(),
  title: z.string().min(1).max(240),
  startsAt: UTCInstantSchema,
  endsAt: UTCInstantSchema,
  replacesBlockId: z.uuid().nullable(),
  reasonCodes: z.array(z.string().regex(/^[A-Z][A-Z0-9_]*$/)).min(1).max(20),
}).strict().refine(
  (block) => Date.parse(block.endsAt) > Date.parse(block.startsAt),
  "proposed block must have positive duration",
);

export const ConstraintViolationSchema = z.object({
  constraintId: z.string().min(1),
  code: z.string().regex(/^[A-Z][A-Z0-9_]*$/),
  message: z.string().min(1).max(500),
  taskId: z.uuid().optional(),
  blockIds: z.array(z.uuid()).max(20),
}).strict();

export const ScoreBreakdownSchema = z.object({
  urgency: z.number(),
  priority: z.number(),
  preference: z.number(),
  energyMatch: z.number(),
  completionProbability: z.number(),
  contextSwitchPenalty: z.number(),
  fragmentationPenalty: z.number(),
  scheduleChangePenalty: z.number(),
  lateNightPenalty: z.number(),
}).strict();

export const ScheduleCandidateSchema = z.object({
  id: z.uuid(),
  blocks: z.array(ProposedScheduleBlockSchema),
  score: z.number(),
  scoreBreakdown: ScoreBreakdownSchema,
  changedExistingBlocks: z.number().int().nonnegative(),
  scheduleChangeCost: z.number().nonnegative().default(0),
  hardConstraintViolations: z.array(ConstraintViolationSchema),
}).strict();

export const PlanningDiagnosticSchema = z.object({
  code: z.string().regex(/^[A-Z][A-Z0-9_]*$/),
  message: z.string().min(1).max(500),
  candidateId: z.uuid().optional(),
  taskId: z.uuid().optional(),
}).strict();

export const PlanningResultSchema = z.discriminatedUnion("status", [
  z.object({
    status: z.literal("success"),
    candidates: z.array(ScheduleCandidateSchema).min(1),
    diagnostics: z.array(PlanningDiagnosticSchema),
  }).strict(),
  z.object({
    status: z.literal("no_feasible_plan"),
    candidates: z.array(ScheduleCandidateSchema).length(0),
    diagnostics: z.array(PlanningDiagnosticSchema).min(1),
  }).strict(),
]);

export type PlanningRequest = z.infer<typeof PlanningRequestSchema>;
export type ProposedScheduleBlock = z.infer<typeof ProposedScheduleBlockSchema>;
export type ConstraintViolation = z.infer<typeof ConstraintViolationSchema>;
export type ScoreBreakdown = z.infer<typeof ScoreBreakdownSchema>;
export type ScheduleCandidate = z.infer<typeof ScheduleCandidateSchema>;
export type PlanningDiagnostic = z.infer<typeof PlanningDiagnosticSchema>;
export type PlanningResult = z.infer<typeof PlanningResultSchema>;

export interface RawScheduleCandidate {
  id: string;
  blocks: ProposedScheduleBlock[];
  changedExistingBlocks: number;
  scheduleChangeCost?: number;
}

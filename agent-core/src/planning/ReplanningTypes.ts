import { z } from "zod";
import { StateSnapshotSchema } from "../agent/state/StateSnapshot.js";
import { TimeRangeSchema, UTCInstantSchema } from "../agent/state/StateModels.js";
import { UUIDSchema } from "../agent/schemas/Common.js";
import { DomainEventSchema } from "../events/DomainEvent.js";
import { ProposedScheduleBlockSchema, ScheduleCandidateSchema } from "./PlanningTypes.js";

export const ReplanningScopeSchema = z.enum(["local", "day", "multi_day", "full"]);

export const ReplanningDecisionSchema = z.discriminatedUnion("action", [
  z.object({
    action: z.literal("no_replan"),
    reasonCodes: z.array(z.string().regex(/^[A-Z][A-Z0-9_]*$/)).min(1),
    confidence: z.number().min(0).max(1),
  }).strict(),
  z.object({
    action: z.literal("replan"),
    scope: ReplanningScopeSchema,
    affectedTaskIds: z.array(UUIDSchema).max(100),
    affectedRange: TimeRangeSchema,
    reasonCodes: z.array(z.string().regex(/^[A-Z][A-Z0-9_]*$/)).min(1),
    confidence: z.number().min(0).max(1),
  }).strict(),
]);

export const PlanChangeSchema = z.object({
  type: z.enum(["UNCHANGED", "ADD", "MOVE", "RESIZE", "REMOVE"]),
  taskId: UUIDSchema.optional(),
  previousBlockId: UUIDSchema.optional(),
  proposedBlockId: UUIDSchema.optional(),
  previousRange: TimeRangeSchema.optional(),
  proposedRange: TimeRangeSchema.optional(),
  cost: z.number().nonnegative(),
  reasonCodes: z.array(z.string().regex(/^[A-Z][A-Z0-9_]*$/)).min(1),
}).strict().superRefine((change, context) => {
  const requiresPrevious = change.type === "UNCHANGED" || change.type === "MOVE" || change.type === "RESIZE" || change.type === "REMOVE";
  const requiresProposed = change.type === "UNCHANGED" || change.type === "MOVE" || change.type === "RESIZE" || change.type === "ADD";
  if (requiresPrevious && (change.previousBlockId === undefined || change.previousRange === undefined)) {
    context.addIssue({ code: "custom", message: `${change.type} requires a previous block and range` });
  }
  if (requiresProposed && (change.proposedBlockId === undefined || change.proposedRange === undefined)) {
    context.addIssue({ code: "custom", message: `${change.type} requires a proposed block and range` });
  }
});

export const PlanRevisionSchema = z.object({
  planId: UUIDSchema,
  revisionId: UUIDSchema,
  revision: z.number().int().positive(),
  previousRevisionId: UUIDSchema.nullable(),
  status: z.literal("proposed"),
  userId: z.string().min(1),
  sourceEventId: UUIDSchema,
  createdAt: UTCInstantSchema,
  createdFromState: UUIDSchema,
  baseStateRevision: z.number().int().nonnegative(),
  scope: ReplanningScopeSchema,
  blocks: z.array(ProposedScheduleBlockSchema),
  changes: z.array(PlanChangeSchema),
  score: z.number(),
  scheduleChangeCost: z.number().nonnegative(),
  risk: z.enum(["low", "medium", "high"]),
  confidence: z.number().min(0).max(1),
  requiresConfirmation: z.boolean(),
}).strict();

export const ReplanningRequestSchema = z.object({
  event: DomainEventSchema,
  state: StateSnapshotSchema,
  planId: UUIDSchema.optional(),
  candidateLimit: z.number().int().min(1).max(10).default(3),
  slotGranularityMinutes: z.union([z.literal(5), z.literal(10), z.literal(15), z.literal(30), z.literal(60)]).default(10),
  maximumDailyFocusMinutes: z.number().int().min(30).max(960).default(360),
}).strict().refine((request) => request.event.userId === request.state.userId, {
  path: ["event", "userId"],
  message: "event user must match the state snapshot user",
});

export const ReplanningResultSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("no_replan"), decision: ReplanningDecisionSchema, diagnostics: z.array(z.string()) }).strict(),
  z.object({
    status: z.literal("proposal"),
    decision: ReplanningDecisionSchema,
    candidate: ScheduleCandidateSchema,
    revision: PlanRevisionSchema,
    diagnostics: z.array(z.string()),
  }).strict(),
  z.object({
    status: z.literal("no_feasible_plan"),
    decision: ReplanningDecisionSchema,
    diagnostics: z.array(z.string()).min(1),
  }).strict(),
]);

export type ReplanningScope = z.infer<typeof ReplanningScopeSchema>;
export type ReplanningDecision = z.infer<typeof ReplanningDecisionSchema>;
export type PlanChange = z.infer<typeof PlanChangeSchema>;
export type PlanRevision = z.infer<typeof PlanRevisionSchema>;
export type ReplanningRequest = z.infer<typeof ReplanningRequestSchema>;
export type ReplanningResult = z.infer<typeof ReplanningResultSchema>;

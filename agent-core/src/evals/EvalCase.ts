import { z } from "zod";
import { INTENTS } from "../agent/schemas/Intent.js";
import { StateSnapshotSchema } from "../agent/state/StateSnapshot.js";
import { ProposedScheduleBlockSchema } from "../planning/PlanningTypes.js";

export const EVAL_CATEGORIES = [
  "intent", "constraint", "deadline", "replanning", "stability", "safety", "tool",
] as const;

export const GRADER_IDS = [
  "intent", "tool_selection", "hard_constraints", "deadline", "stability", "safety", "plan_available",
] as const;

export const EvalExpectedSchema = z.object({
  intent: z.enum(INTENTS).optional(),
  mustCallTools: z.array(z.string().min(1)).optional(),
  mustNotCallTools: z.array(z.string().min(1)).optional(),
  mustPreserveEvents: z.array(z.uuid()).optional(),
  maxScheduleChanges: z.number().int().nonnegative().optional(),
  policyDecision: z.enum(["allow", "ask_user", "deny"]).optional(),
  requirePlan: z.boolean().optional(),
}).strict();

export const EvalCaseSchema = z.object({
  id: z.string().regex(/^[a-z][a-z0-9_-]{2,119}$/),
  category: z.enum(EVAL_CATEGORIES),
  initialState: StateSnapshotSchema,
  userInput: z.string().min(1).max(2_000),
  expected: EvalExpectedSchema,
  graders: z.array(z.enum(GRADER_IDS)).min(1),
}).strict();

export const EvalObservationSchema = z.object({
  intent: z.enum(INTENTS).optional(),
  calledTools: z.array(z.string()).default([]),
  proposedBlocks: z.array(ProposedScheduleBlockSchema).default([]),
  preservedEventIds: z.array(z.uuid()).default([]),
  scheduleChanges: z.number().int().nonnegative().default(0),
  policyDecision: z.enum(["allow", "ask_user", "deny"]).optional(),
  status: z.enum(["success", "proposal", "no_replan", "no_feasible_plan", "failed"]).default("success"),
  diagnostics: z.array(z.string()).default([]),
}).strict();

export type EvalCategory = z.infer<typeof EvalCaseSchema>["category"];
export type EvalCase = z.infer<typeof EvalCaseSchema>;
export type EvalExpected = z.infer<typeof EvalExpectedSchema>;
export type EvalObservation = z.infer<typeof EvalObservationSchema>;
export type GraderId = z.infer<typeof EvalCaseSchema>["graders"][number];

export interface EvalSubject {
  evaluate(evalCase: EvalCase): Promise<EvalObservation>;
}

import { z } from "zod";
import { defineTool, type RegisteredAgentTool, type ToolExecutionContext } from "../../agent/tools/AgentTool.js";
import { TimeRangeSchema } from "../../agent/state/StateModels.js";
import { ConstraintEngine } from "../../planning/ConstraintEngine.js";
import { PlanScorer } from "../../planning/PlanScorer.js";
import { PlanValidator } from "../../planning/PlanValidator.js";
import { SchedulingEngine } from "../../planning/SchedulingEngine.js";
import {
  ConstraintViolationSchema,
  PlanningResultSchema,
  ProposedScheduleBlockSchema,
  ScheduleCandidateSchema,
  ScoreBreakdownSchema,
  type PlanningRequest,
  type RawScheduleCandidate,
} from "../../planning/PlanningTypes.js";

const RequestInputSchema = z.object({
  taskIds: z.array(z.uuid()).min(1).max(100),
  horizon: TimeRangeSchema,
  scope: z.enum(["local", "day", "multi_day", "full"]),
  candidateLimit: z.number().int().min(1).max(10).default(3),
  slotGranularityMinutes: z.union([z.literal(5), z.literal(10), z.literal(15), z.literal(30), z.literal(60)]).default(30),
  maximumDailyFocusMinutes: z.number().int().min(30).max(960).default(360),
}).strict();

const RawCandidateSchema = z.object({
  id: z.uuid(),
  blocks: z.array(ProposedScheduleBlockSchema).max(500),
  changedExistingBlocks: z.number().int().nonnegative(),
  scheduleChangeCost: z.number().nonnegative().optional(),
  score: z.number().optional(),
  scoreBreakdown: ScoreBreakdownSchema.optional(),
  hardConstraintViolations: z.array(ConstraintViolationSchema).optional(),
}).strict();

const CandidateRequestSchema = z.object({
  candidate: RawCandidateSchema,
  planning: RequestInputSchema,
}).strict();

const ValidationOutputSchema = z.object({
  valid: z.boolean(),
  violations: z.array(ConstraintViolationSchema),
  candidate: ScheduleCandidateSchema.optional(),
}).strict();

const ScoreOutputSchema = z.object({ score: z.number(), breakdown: ScoreBreakdownSchema }).strict();

export function createPlanningTools(dependencies: {
  scheduling?: SchedulingEngine;
  validator?: PlanValidator;
  scorer?: PlanScorer;
  constraints?: ConstraintEngine;
} = {}): RegisteredAgentTool[] {
  const scheduling = dependencies.scheduling ?? new SchedulingEngine();
  const validator = dependencies.validator ?? new PlanValidator();
  const scorer = dependencies.scorer ?? new PlanScorer();
  const constraints = dependencies.constraints ?? new ConstraintEngine();
  return [
    defineTool({
      name: "generate_schedule_candidates",
      version: 1,
      description: "Generate deterministic schedule candidates from the authenticated immutable state snapshot.",
      inputSchema: RequestInputSchema,
      outputSchema: PlanningResultSchema,
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read", "planning:read"],
      execute: async (input, context) => scheduling.plan(requestOf(input, context)),
    }),
    defineTool({
      name: "validate_schedule_plan",
      version: 1,
      description: "Validate a proposed schedule against all hard constraints without changing state.",
      inputSchema: CandidateRequestSchema,
      outputSchema: ValidationOutputSchema,
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read", "planning:read"],
      execute: async (input, context) => validator.validate(rawCandidate(input.candidate), requestOf(input.planning, context)),
    }),
    defineTool({
      name: "score_schedule_plan",
      version: 1,
      description: "Score a proposed schedule with the deterministic planning rubric.",
      inputSchema: CandidateRequestSchema,
      outputSchema: ScoreOutputSchema,
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read", "planning:read"],
      execute: async (input, context) => scorer.score(rawCandidate(input.candidate), requestOf(input.planning, context)),
    }),
    defineTool({
      name: "find_schedule_conflicts",
      version: 1,
      description: "Return hard-constraint conflicts for a proposed schedule without applying it.",
      inputSchema: CandidateRequestSchema,
      outputSchema: z.object({ conflicts: z.array(ConstraintViolationSchema) }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read", "planning:read"],
      execute: async (input, context) => ({
        conflicts: constraints.validate(rawCandidate(input.candidate), requestOf(input.planning, context)),
      }),
    }),
    defineTool({
      name: "simulate_schedule_change",
      version: 1,
      description: "Simulate and summarize a candidate's schedule changes; never persists the result.",
      inputSchema: CandidateRequestSchema,
      outputSchema: z.object({
        candidate: RawCandidateSchema,
        conflicts: z.array(ConstraintViolationSchema),
        changedExistingBlocks: z.number().int().nonnegative(),
        resultingFocusMinutes: z.number().int().nonnegative(),
      }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read", "planning:read"],
      execute: async (input, context) => ({
        candidate: input.candidate,
        conflicts: constraints.validate(rawCandidate(input.candidate), requestOf(input.planning, context)),
        changedExistingBlocks: input.candidate.changedExistingBlocks,
        resultingFocusMinutes: input.candidate.blocks.reduce(
          (total, block) => total + (Date.parse(block.endsAt) - Date.parse(block.startsAt)) / 60_000,
          0,
        ),
      }),
    }),
  ];
}

function requestOf(
  input: z.infer<typeof RequestInputSchema>,
  context: ToolExecutionContext,
): PlanningRequest {
  return {
    ...input,
    state: context.state,
  };
}

export type PlanningToolCandidate = z.infer<typeof RawCandidateSchema> & RawScheduleCandidate;

function rawCandidate(value: z.infer<typeof RawCandidateSchema>): RawScheduleCandidate {
  return {
    id: value.id,
    blocks: value.blocks,
    changedExistingBlocks: value.changedExistingBlocks,
    ...(value.scheduleChangeCost === undefined ? {} : { scheduleChangeCost: value.scheduleChangeCost }),
  };
}

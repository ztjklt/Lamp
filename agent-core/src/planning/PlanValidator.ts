import { ScheduleCandidateSchema, type PlanningRequest, type RawScheduleCandidate, type ScheduleCandidate, type ConstraintViolation } from "./PlanningTypes.js";
import { ConstraintEngine } from "./ConstraintEngine.js";
import { PlanScorer } from "./PlanScorer.js";

export interface PlanValidationResult {
  valid: boolean;
  violations: ConstraintViolation[];
  candidate?: ScheduleCandidate;
}

export class PlanValidator {
  constructor(
    private readonly constraints = new ConstraintEngine(),
    private readonly scorer = new PlanScorer(),
  ) {}

  validate(raw: RawScheduleCandidate, request: PlanningRequest): PlanValidationResult {
    const violations = this.constraints.validate(raw, request);
    if (violations.length > 0) return { valid: false, violations };
    const scored = this.scorer.score(raw, request);
    const candidate = ScheduleCandidateSchema.parse({
      ...raw,
      score: scored.score,
      scoreBreakdown: scored.breakdown,
      hardConstraintViolations: [],
    });
    return { valid: true, violations: [], candidate };
  }
}

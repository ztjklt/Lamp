import type { ConstraintViolation, PlanningRequest, RawScheduleCandidate } from "./PlanningTypes.js";
import { DEFAULT_HARD_CONSTRAINTS, type HardConstraint } from "./constraints/HardConstraints.js";

export class ConstraintEngine {
  constructor(private readonly constraints: readonly HardConstraint[] = DEFAULT_HARD_CONSTRAINTS) {}

  validate(candidate: RawScheduleCandidate, request: PlanningRequest): ConstraintViolation[] {
    return this.constraints.flatMap((constraint) => constraint.validate(candidate, request));
  }
}

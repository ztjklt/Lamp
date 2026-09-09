import type { EvalCase, EvalObservation } from "../EvalCase.js";

export type SubjectiveCriterion = "response_naturality" | "explanation_quality" | "preference_alignment";

export interface SubjectiveGrade {
  criterion: SubjectiveCriterion;
  score: number;
  reason: string;
}

/** Optional manual/nightly boundary. Hard constraints must never use this grader. */
export interface LLMGrader {
  grade(input: {
    evalCase: EvalCase;
    observation: EvalObservation;
    criterion: SubjectiveCriterion;
  }): Promise<SubjectiveGrade>;
}

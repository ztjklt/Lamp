import { EvalCaseSchema, EvalObservationSchema, EVAL_CATEGORIES, type EvalCase, type EvalSubject } from "./EvalCase.js";
import { deterministicGraders, type GraderResult } from "./graders/DeterministicGraders.js";

export interface EvalCaseResult {
  caseId: string;
  category: EvalCase["category"];
  passed: boolean;
  graders: GraderResult[];
}

export interface EvalMetrics {
  totalCases: number;
  passedCases: number;
  failedCases: number;
  passRate: number;
  categoryPassRates: Record<EvalCase["category"], number>;
  graderPassRates: Record<string, number>;
}

export interface EvalRunResult {
  metrics: EvalMetrics;
  cases: EvalCaseResult[];
}

export class EvalRunner {
  async run(rawCases: readonly EvalCase[], subject: EvalSubject): Promise<EvalRunResult> {
    const cases = rawCases.map((item) => EvalCaseSchema.parse(item));
    if (new Set(cases.map((item) => item.id)).size !== cases.length) throw new Error("Eval case IDs must be unique");
    const results: EvalCaseResult[] = [];
    for (const evalCase of cases) {
      try {
        const observation = EvalObservationSchema.parse(await subject.evaluate(evalCase));
        const graders = evalCase.graders.map((grader) => deterministicGraders[grader](evalCase, observation));
        results.push({ caseId: evalCase.id, category: evalCase.category, passed: graders.every((item) => item.passed), graders });
      } catch (error) {
        results.push({
          caseId: evalCase.id,
          category: evalCase.category,
          passed: false,
          graders: evalCase.graders.map((grader) => ({
            grader,
            passed: false,
            reasonCode: "EVAL_SUBJECT_FAILED",
            detail: error instanceof Error ? error.message : "Unknown evaluation failure",
          })),
        });
      }
    }
    return { metrics: metrics(results), cases: results };
  }
}

function metrics(results: readonly EvalCaseResult[]): EvalMetrics {
  const passedCases = results.filter((item) => item.passed).length;
  const categoryPassRates = Object.fromEntries(EVAL_CATEGORIES.map((category) => {
    const selected = results.filter((item) => item.category === category);
    return [category, rate(selected.filter((item) => item.passed).length, selected.length)];
  })) as EvalMetrics["categoryPassRates"];
  const graderIds = [...new Set(results.flatMap((item) => item.graders.map((grader) => grader.grader)))];
  const graderPassRates = Object.fromEntries(graderIds.map((grader) => {
    const selected = results.flatMap((item) => item.graders).filter((item) => item.grader === grader);
    return [grader, rate(selected.filter((item) => item.passed).length, selected.length)];
  }));
  return {
    totalCases: results.length,
    passedCases,
    failedCases: results.length - passedCases,
    passRate: rate(passedCases, results.length),
    categoryPassRates,
    graderPassRates,
  };
}

function rate(passed: number, total: number): number {
  return total === 0 ? 0 : Math.round((passed / total) * 10_000) / 10_000;
}

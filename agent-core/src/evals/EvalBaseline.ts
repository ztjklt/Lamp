import { z } from "zod";
import type { EvalRunResult } from "./EvalRunner.js";
import { EVAL_CATEGORIES } from "./EvalCase.js";

export const EvalBaselineSchema = z.object({
  version: z.string().min(1),
  caseCount: z.number().int().min(100),
  minimumPassRate: z.number().min(0).max(1),
  minimumCategoryPassRate: z.number().min(0).max(1),
  referenceMetrics: z.object({
    passRate: z.number().min(0).max(1),
    categoryPassRates: z.record(z.string(), z.number().min(0).max(1)),
  }).strict(),
}).strict();

export type EvalBaseline = z.infer<typeof EvalBaselineSchema>;

export interface RegressionGateResult {
  passed: boolean;
  failures: string[];
}

export function evaluateRegressionGate(run: EvalRunResult, rawBaseline: unknown): RegressionGateResult {
  const baseline = EvalBaselineSchema.parse(rawBaseline);
  const failures: string[] = [];
  if (run.metrics.totalCases < baseline.caseCount) {
    failures.push(`CASE_COUNT:${run.metrics.totalCases}<${baseline.caseCount}`);
  }
  if (run.metrics.passRate < baseline.minimumPassRate) {
    failures.push(`PASS_RATE:${run.metrics.passRate}<${baseline.minimumPassRate}`);
  }
  for (const category of EVAL_CATEGORIES) {
    const actual = run.metrics.categoryPassRates[category];
    const reference = baseline.referenceMetrics.categoryPassRates[category];
    const allowed = Math.max(baseline.minimumCategoryPassRate, (reference ?? 1) - 0.02);
    if (actual < allowed) failures.push(`CATEGORY_${category.toUpperCase()}:${actual}<${allowed}`);
  }
  return { passed: failures.length === 0, failures };
}

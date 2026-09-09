import { readFile } from "node:fs/promises";
import { EvalBaselineSchema, evaluateRegressionGate } from "./EvalBaseline.js";
import { EvalRunner } from "./EvalRunner.js";
import { ReferenceEvalSubject } from "./ReferenceEvalSubject.js";
import { initialEvalDataset } from "./datasets/InitialEvalDataset.js";

const baselineUrl = new URL("../../evals/baseline-v1.json", import.meta.url);
const baseline = EvalBaselineSchema.parse(JSON.parse(await readFile(baselineUrl, "utf8")));
const run = await new EvalRunner().run(initialEvalDataset, new ReferenceEvalSubject());
const gate = evaluateRegressionGate(run, baseline);
const report = {
  baselineVersion: baseline.version,
  ...run.metrics,
  regressionGate: gate,
  failures: run.cases.filter((item) => !item.passed),
};
process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
if (!gate.passed) process.exitCode = 1;

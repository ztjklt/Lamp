import { describe, expect, it } from "vitest";
import type { EvalObservation, EvalSubject } from "../src/evals/EvalCase.js";
import { evaluateRegressionGate } from "../src/evals/EvalBaseline.js";
import { EvalRunner } from "../src/evals/EvalRunner.js";
import { ReferenceEvalSubject } from "../src/evals/ReferenceEvalSubject.js";
import { initialEvalDataset } from "../src/evals/datasets/InitialEvalDataset.js";
import {
  ExamTomorrow,
  LateWakeUp,
  LockedClassConflict,
  NewUrgentTask,
  OverloadedDay,
  StudentNormalDay,
  TaskMissed,
} from "../src/evals/fixtures/EvalFixtures.js";
import { StateSnapshotSchema } from "../src/agent/state/StateSnapshot.js";

const baseline = {
  version: "test",
  caseCount: 105,
  minimumPassRate: 0.98,
  minimumCategoryPassRate: 0.95,
  referenceMetrics: {
    passRate: 1,
    categoryPassRates: {
      intent: 1, constraint: 1, deadline: 1, replanning: 1, stability: 1, safety: 1, tool: 1,
    },
  },
};

describe("Phase 8 eval harness", () => {
  it("provides all seven documented reusable state fixtures", () => {
    const fixtures = [
      StudentNormalDay(), ExamTomorrow(), OverloadedDay(), LateWakeUp(),
      TaskMissed(), NewUrgentTask(), LockedClassConflict(),
    ];
    expect(fixtures.every((fixture) => StateSnapshotSchema.safeParse(fixture).success)).toBe(true);
  });

  it("contains 105 unique cases evenly distributed across all seven required categories", () => {
    expect(initialEvalDataset).toHaveLength(105);
    expect(new Set(initialEvalDataset.map((item) => item.id)).size).toBe(105);
    const counts = initialEvalDataset.reduce<Record<string, number>>((result, item) => ({
      ...result,
      [item.category]: (result[item.category] ?? 0) + 1,
    }), {});
    expect(counts).toEqual({
      intent: 15,
      constraint: 15,
      deadline: 15,
      replanning: 15,
      stability: 15,
      safety: 15,
      tool: 15,
    });
  });

  it("passes the checked-in offline reference baseline without a live model", async () => {
    const run = await new EvalRunner().run(initialEvalDataset, new ReferenceEvalSubject());
    expect(run.metrics).toMatchObject({ totalCases: 105, passedCases: 105, passRate: 1 });
    expect(evaluateRegressionGate(run, baseline)).toEqual({ passed: true, failures: [] });
  });

  it("fails the regression gate when one category falls beyond its allowed threshold", async () => {
    const reference = new ReferenceEvalSubject();
    const degraded: EvalSubject = {
      evaluate: async (evalCase): Promise<EvalObservation> => evalCase.id === "intent-001"
        ? { intent: "unknown", calledTools: [], proposedBlocks: [], preservedEventIds: [], scheduleChanges: 0, status: "success", diagnostics: [] }
        : reference.evaluate(evalCase),
    };
    const run = await new EvalRunner().run(initialEvalDataset, degraded);
    const gate = evaluateRegressionGate(run, baseline);
    expect(gate.passed).toBe(false);
    expect(gate.failures).toContainEqual(expect.stringContaining("CATEGORY_INTENT"));
  });

  it("detects a deterministic calendar conflict without asking another LLM", async () => {
    const selected = initialEvalDataset.find((item) => item.id === "constraint-001")!;
    const event = selected.initialState.upcomingEvents[0]!;
    const task = selected.initialState.activeTasks[0]!;
    const conflicting: EvalSubject = {
      evaluate: async () => ({
        calledTools: [],
        proposedBlocks: [{
          id: "00000000-0000-4000-8000-000000000801",
          taskId: task.id,
          title: task.title,
          startsAt: event.startsAt,
          endsAt: event.endsAt,
          replacesBlockId: null,
          reasonCodes: ["EVAL_INJECTED_CONFLICT"],
        }],
        preservedEventIds: [event.id],
        scheduleChanges: 0,
        status: "success",
        diagnostics: [],
      }),
    };
    const run = await new EvalRunner().run([selected], conflicting);
    expect(run.cases[0]).toMatchObject({
      passed: false,
      graders: expect.arrayContaining([expect.objectContaining({ grader: "hard_constraints", passed: false })]),
    });
  });
});

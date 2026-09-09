import { describe, expect, it } from "vitest";
import { SchedulingEngine } from "../src/planning/SchedulingEngine.js";
import { makeStateSnapshot, fixtureIds } from "./fixtures/StateFixture.js";

function request(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const state = makeStateSnapshot();
  return {
    state,
    taskIds: [fixtureIds.task],
    horizon: state.planningHorizon,
    scope: "day",
    candidateLimit: 3,
    slotGranularityMinutes: 10,
    maximumDailyFocusMinutes: 360,
    ...overrides,
  };
}

describe("SchedulingEngine", () => {
  it("produces deterministic, scored, hard-constraint-safe candidates", () => {
    const engine = new SchedulingEngine();
    const first = engine.plan(request());
    const second = engine.plan(request());

    expect(first).toEqual(second);
    expect(first.status).toBe("success");
    if (first.status !== "success") return;
    expect(first.candidates.length).toBeGreaterThanOrEqual(2);
    expect(first.candidates.map((candidate) => candidate.score)).toEqual(
      [...first.candidates.map((candidate) => candidate.score)].sort((left, right) => right - left),
    );
    for (const candidate of first.candidates) {
      expect(candidate.hardConstraintViolations).toEqual([]);
      expect(candidate.changedExistingBlocks).toBe(0);
      expect(candidate.blocks.reduce((sum, block) =>
        sum + (Date.parse(block.endsAt) - Date.parse(block.startsAt)) / 60_000, 0)).toBe(120);
      expect(candidate.blocks.every((block) => block.replacesBlockId === null)).toBe(true);
      expect(candidate.blocks.some((block) =>
        Date.parse(block.startsAt) < Date.parse("2026-09-08T10:00:00Z") &&
        Date.parse(block.endsAt) > Date.parse("2026-09-08T09:00:00Z"))).toBe(false);
    }
  });

  it("returns a diagnostic instead of a partial plan when capacity is insufficient", () => {
    const result = new SchedulingEngine().plan(request({ maximumDailyFocusMinutes: 60 }));
    expect(result.status).toBe("no_feasible_plan");
    expect(result.candidates).toEqual([]);
    expect(result.diagnostics).toContainEqual(expect.objectContaining({ code: "NO_FEASIBLE_PLAN" }));
  });

  it("rejects duplicate task identifiers at its input boundary", () => {
    expect(() => new SchedulingEngine().plan(request({ taskIds: [fixtureIds.task, fixtureIds.task] }))).toThrow();
  });
});

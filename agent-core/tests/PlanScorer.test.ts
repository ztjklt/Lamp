import { describe, expect, it } from "vitest";
import { PlanScorer } from "../src/planning/PlanScorer.js";
import { PlanningRequestSchema, type RawScheduleCandidate } from "../src/planning/PlanningTypes.js";
import { fixtureIds, makeStateSnapshot } from "./fixtures/StateFixture.js";

function raw(id: string, startsAt: string, endsAt: string): RawScheduleCandidate {
  return {
    id,
    changedExistingBlocks: 0,
    blocks: [{
      id: id === "00000000-0000-4000-8000-000000000301"
        ? "00000000-0000-4000-8000-000000000303" : "00000000-0000-4000-8000-000000000304",
      taskId: fixtureIds.task,
      title: "复习高数",
      startsAt,
      endsAt,
      replacesBlockId: null,
      reasonCodes: ["TEST"],
    }],
  };
}

describe("PlanScorer", () => {
  it("uses the centralized formula and rewards a preferred period over late night", () => {
    const state = makeStateSnapshot();
    const request = PlanningRequestSchema.parse({
      state,
      taskIds: [fixtureIds.task],
      horizon: state.planningHorizon,
      scope: "day",
      candidateLimit: 2,
      slotGranularityMinutes: 10,
      maximumDailyFocusMinutes: 360,
    });
    const scorer = new PlanScorer();
    const preferred = scorer.score(raw(
      "00000000-0000-4000-8000-000000000301",
      "2026-09-08T08:00:00Z",
      "2026-09-08T10:00:00Z",
    ), request);
    const late = scorer.score(raw(
      "00000000-0000-4000-8000-000000000302",
      "2026-09-08T16:00:00Z",
      "2026-09-08T18:00:00Z",
    ), request);
    expect(preferred.score).toBeGreaterThan(late.score);
    expect(preferred.score).toBe(
      preferred.breakdown.urgency + preferred.breakdown.priority + preferred.breakdown.preference +
      preferred.breakdown.energyMatch + preferred.breakdown.completionProbability -
      preferred.breakdown.contextSwitchPenalty - preferred.breakdown.fragmentationPenalty -
      preferred.breakdown.scheduleChangePenalty - preferred.breakdown.lateNightPenalty,
    );
  });
});

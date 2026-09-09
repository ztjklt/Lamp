import { describe, expect, it } from "vitest";
import { PlanStability } from "../src/planning/PlanStability.js";
import { fixtureIds } from "./fixtures/StateFixture.js";

const oldBlock = {
  id: "00000000-0000-4000-8000-000000000510",
  taskId: fixtureIds.task,
  title: "复习高数",
  startsAt: "2026-09-08T10:00:00Z",
  endsAt: "2026-09-08T11:00:00Z",
  kind: "focus" as const,
  state: "planned" as const,
  locked: false,
  provenance: "fixture",
  reasonCodes: ["USER_REQUESTED_PLAN"],
  revision: 1,
};

function proposed(start: string, end: string) {
  return {
    id: "00000000-0000-4000-8000-000000000511",
    taskId: fixtureIds.task,
    title: "复习高数",
    startsAt: start,
    endsAt: end,
    replacesBlockId: null,
    reasonCodes: ["EARLIEST_AVAILABLE"],
  };
}

describe("PlanStability", () => {
  it("assigns zero cost to an unchanged block", () => {
    const result = new PlanStability().compare([oldBlock], [proposed(oldBlock.startsAt, oldBlock.endsAt)], ["USER_REQUESTED_REPLAN"]);
    expect(result.scheduleChangeCost).toBe(0);
    expect(result.changedExistingBlocks).toBe(0);
    expect(result.blocks[0]?.replacesBlockId).toBe(oldBlock.id);
    expect(result.changes[0]?.type).toBe("UNCHANGED");
  });

  it("produces an auditable move diff and positive change cost", () => {
    const result = new PlanStability().compare([oldBlock], [proposed("2026-09-08T12:00:00Z", "2026-09-08T13:00:00Z")], ["TASK_INCOMPLETE_REQUIRES_REALLOCATION"]);
    expect(result.scheduleChangeCost).toBeGreaterThan(0);
    expect(result.changes[0]).toMatchObject({ type: "MOVE", previousBlockId: oldBlock.id, reasonCodes: expect.arrayContaining(["BLOCK_MOVED"]) });
  });
});

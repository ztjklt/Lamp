import { describe, expect, it } from "vitest";
import { ReplanningPolicy } from "../src/planning/ReplanningPolicy.js";
import { fixtureIds, makeStateSnapshot } from "./fixtures/StateFixture.js";

const eventId = "00000000-0000-4000-8000-000000000501";

describe("ReplanningPolicy", () => {
  it("does not churn the schedule after harmless early completion", () => {
    const decision = new ReplanningPolicy().evaluate({
      eventId,
      userId: "user-1",
      occurredAt: "2026-09-08T08:30:00Z",
      type: "TASK_COMPLETED_EARLY",
      payload: { taskId: fixtureIds.task, freedMinutes: 20 },
    }, makeStateSnapshot());
    expect(decision).toMatchObject({ action: "no_replan", reasonCodes: ["EARLY_COMPLETION_CAN_LEAVE_FREE_CAPACITY"] });
  });

  it("ignores a new event that does not conflict with flexible work", () => {
    const decision = new ReplanningPolicy().evaluate({
      eventId,
      userId: "user-1",
      occurredAt: "2026-09-08T08:30:00Z",
      type: "EVENT_ADDED",
      payload: {
        calendarEventId: "00000000-0000-4000-8000-000000000502",
        range: { start: "2026-09-08T13:00:00Z", end: "2026-09-08T14:00:00Z" },
      },
    }, makeStateSnapshot());
    expect(decision.action).toBe("no_replan");
  });

  it("uses local scope for an incomplete task", () => {
    const decision = new ReplanningPolicy().evaluate({
      eventId,
      userId: "user-1",
      occurredAt: "2026-09-08T11:45:00Z",
      type: "TASK_INCOMPLETE",
      payload: { taskId: fixtureIds.task, additionalMinutes: 30 },
    }, makeStateSnapshot());
    expect(decision).toMatchObject({ action: "replan", scope: "local", affectedTaskIds: [fixtureIds.task] });
  });
});

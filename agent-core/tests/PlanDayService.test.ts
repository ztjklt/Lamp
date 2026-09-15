import { describe, expect, it } from "vitest";
import { PlanDayRequestSchema } from "../src/api/PlanDayContract.js";
import { PlanDayService } from "../src/api/PlanDayService.js";

const ids = {
  request: "10000000-0000-4000-8000-000000000001",
  task: "10000000-0000-4000-8000-000000000002",
  event: "10000000-0000-4000-8000-000000000003",
};

function request() {
  return {
    schemaVersion: 1 as const,
    requestId: ids.request,
    sourceFingerprint: "a".repeat(64),
    requestedAt: "2026-09-08T01:00:00Z",
    timezone: "Asia/Singapore",
    locale: "zh-CN",
    horizon: { start: "2026-09-08T01:00:00Z", end: "2026-09-08T15:00:00Z" },
    tasks: [{
      id: ids.task,
      goalId: null,
      title: "复习高数",
      detail: "第二章",
      importance: 5,
      deadline: "2026-09-08T14:00:00Z",
      estimatedMinutes: 60,
      remainingMinutes: 60,
      isPaused: false,
      isSplittable: true,
      minimumSessionMinutes: 15,
      maximumSessionMinutes: 90,
      preferredPeriods: ["morning" as const],
      dependencyIds: [],
      availableWindows: [],
    }],
    schedule: [{
      id: ids.event,
      taskId: null,
      title: "课程",
      startsAt: "2026-09-08T02:00:00Z",
      endsAt: "2026-09-08T03:00:00Z",
      kind: "fixed" as const,
      state: "planned" as const,
      locked: true,
      provenance: "Lamp Calendar",
    }],
    preferences: {
      preferredSleepTime: "23:30",
      preferredWakeTime: "08:00",
      preferredFocusMinutes: 45,
      preferredBreakMinutes: 10,
      morningStudyPreference: 0.8,
      eveningStudyPreference: 0.2,
    },
  };
}

describe("PlanDayService", () => {
  it("returns an explicit proposal without touching a fixed event", () => {
    const response = new PlanDayService().createProposal(request());

    expect(response.status).toBe("proposal");
    expect(response.commitRequired).toBe(true);
    expect(response.sourceFingerprint).toBe("a".repeat(64));
    if (response.status !== "proposal") throw new Error("expected proposal");
    expect(response.proposal.blocks).not.toHaveLength(0);
    expect(response.proposal.blocks.every((block) =>
      Date.parse(block.endsAt) <= Date.parse("2026-09-08T02:00:00Z") ||
      Date.parse(block.startsAt) >= Date.parse("2026-09-08T03:00:00Z")
    )).toBe(true);
  });

  it("returns no feasible plan when there is no unplanned work", () => {
    const input = request();
    input.tasks[0]!.remainingMinutes = 0;

    const response = new PlanDayService().createProposal(input);

    expect(response.status).toBe("no_feasible_plan");
    expect(response.commitRequired).toBe(true);
  });

  it("accounts for focus time already spent before the planning horizon", () => {
    const input = request();
    Object.assign(input, { focusMinutesBeforeHorizon: 340 });

    const response = new PlanDayService().createProposal(input);

    expect(response.status).toBe("no_feasible_plan");
    expect(response.diagnostics[0]).toContain("安全上限");
  });

  it("accepts omitted optional sleep preferences from Swift encoding", () => {
    const input = request();
    const {
      preferredSleepTime: _sleep,
      preferredWakeTime: _wake,
      ...preferences
    } = input.preferences;

    const response = new PlanDayService().createProposal({ ...input, preferences });

    expect(response.status).toBe("proposal");
  });

  it("rejects schedule blocks outside the day horizon", () => {
    const input = request();
    input.schedule[0]!.startsAt = "2026-09-09T02:00:00Z";
    input.schedule[0]!.endsAt = "2026-09-09T03:00:00Z";

    expect(() => PlanDayRequestSchema.parse(input)).toThrow();
  });
});

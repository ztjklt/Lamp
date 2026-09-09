import { describe, expect, it } from "vitest";
import { IdempotencyConflictError, IncompleteReplanService } from "../src/api/IncompleteReplanService.js";

const ids = {
  event: "20000000-0000-4000-8000-000000000001",
  mathTask: "20000000-0000-4000-8000-000000000002",
  englishTask: "20000000-0000-4000-8000-000000000003",
  mathBlock: "20000000-0000-4000-8000-000000000004",
  englishBlock: "20000000-0000-4000-8000-000000000005",
  fixedBlock: "20000000-0000-4000-8000-000000000006",
  laterMathBlock: "20000000-0000-4000-8000-000000000007",
};

function request() {
  return {
    schemaVersion: 1 as const,
    eventId: ids.event,
    sourceFingerprint: "b".repeat(64),
    occurredAt: "2026-09-08T11:45:00Z",
    timezone: "Asia/Singapore",
    locale: "zh-CN",
    planningHorizon: { start: "2026-09-08T11:00:00Z", end: "2026-09-11T16:00:00Z" },
    taskId: ids.mathTask,
    incompleteBlockId: ids.mathBlock,
    additionalMinutes: 60,
    tasks: [
      {
        id: ids.mathTask, goalId: null, title: "复习高数", detail: "第二章", importance: 5,
        deadline: "2026-09-09T15:00:00Z", estimatedMinutes: 60, remainingMinutes: 60,
        isPaused: false, isSplittable: true, minimumSessionMinutes: 15, maximumSessionMinutes: 90,
        preferredPeriods: ["evening" as const], dependencyIds: [], availableWindows: [],
      },
      {
        id: ids.englishTask, goalId: null, title: "复习英语", detail: "阅读", importance: 3,
        deadline: null, estimatedMinutes: 50, remainingMinutes: 50,
        isPaused: false, isSplittable: true, minimumSessionMinutes: 15, maximumSessionMinutes: 90,
        preferredPeriods: ["evening" as const], dependencyIds: [], availableWindows: [],
      },
    ],
    schedule: [
      {
        id: ids.mathBlock, taskId: ids.mathTask, title: "复习高数",
        startsAt: "2026-09-08T11:00:00Z", endsAt: "2026-09-08T12:00:00Z",
        kind: "focus" as const, state: "missed" as const, locked: false, provenance: "Lamp",
      },
      {
        id: ids.englishBlock, taskId: ids.englishTask, title: "复习英语",
        startsAt: "2026-09-08T12:10:00Z", endsAt: "2026-09-08T13:00:00Z",
        kind: "focus" as const, state: "planned" as const, locked: false, provenance: "Lamp",
      },
      {
        id: ids.fixedBlock, taskId: null, title: "固定课程",
        startsAt: "2026-09-08T13:15:00Z", endsAt: "2026-09-08T14:00:00Z",
        kind: "fixed" as const, state: "planned" as const, locked: true, provenance: "Calendar",
      },
    ],
    preferences: {
      preferredFocusMinutes: 50, preferredBreakMinutes: 10,
      morningStudyPreference: 0.2, eveningStudyPreference: 0.8,
    },
  };
}

describe("IncompleteReplanService", () => {
  it("moves only the missed session while preserving unrelated and fixed blocks", async () => {
    const input = request();
    const original = structuredClone(input);
    const response = await new IncompleteReplanService().createProposal(input);

    expect(input).toEqual(original);
    expect(response).toMatchObject({ status: "proposal", commitRequired: true, eventId: ids.event });
    if (response.status !== "proposal") throw new Error("expected proposal");
    expect(response.proposal.scope).toBe("local");
    expect(response.proposal.sourceEventId).toBe(ids.event);
    expect(response.proposal.changes).toEqual(expect.arrayContaining([
      expect.objectContaining({ type: "MOVE", taskId: ids.mathTask, previousBlockId: ids.mathBlock }),
    ]));
    expect(response.proposal.changes.every((change) => change.taskId === ids.mathTask)).toBe(true);
    expect(JSON.stringify(response.proposal)).not.toContain(ids.englishBlock);
    expect(JSON.stringify(response.proposal)).not.toContain(ids.fixedBlock);
    expect(response.proposal.blocks.length).toBeGreaterThan(0);
    const moved = response.proposal.blocks.find((block) => block.replacesBlockId === ids.mathBlock)!;
    expect(moved.replacesBlockId).toBe(ids.mathBlock);
    expect(response.proposal.blocks.every((block) => Date.parse(block.startsAt) >= Date.parse(input.occurredAt))).toBe(true);
    expect(response.proposal.blocks.every((block) =>
      Date.parse(block.endsAt) <= Date.parse("2026-09-08T12:10:00Z") ||
      Date.parse(block.startsAt) >= Date.parse("2026-09-08T13:00:00Z"))).toBe(true);
    expect(response.proposal.blocks.every((block) =>
      Date.parse(block.endsAt) <= Date.parse("2026-09-08T13:15:00Z") ||
      Date.parse(block.startsAt) >= Date.parse("2026-09-08T14:00:00Z"))).toBe(true);
  });

  it("returns the same proposal for the same user and event", async () => {
    const service = new IncompleteReplanService();
    const first = await service.createProposal(request(), "user-1");
    const second = await service.createProposal(request(), "user-1");
    expect(second).toEqual(first);
  });

  it("allocates the missed work in addition to a later preserved session for the same task", async () => {
    const input = request();
    input.schedule.push({
      id: ids.laterMathBlock, taskId: ids.mathTask, title: "后续高数练习",
      startsAt: "2026-09-09T02:00:00Z", endsAt: "2026-09-09T03:00:00Z",
      kind: "focus", state: "planned", locked: false, provenance: "Lamp",
    });

    const response = await new IncompleteReplanService().createProposal(input);

    expect(response.status).toBe("proposal");
    if (response.status !== "proposal") throw new Error("expected proposal");
    expect(response.proposal.scope).toBe("local");
    const proposedMinutes = response.proposal.blocks.reduce((sum, block) =>
      sum + (Date.parse(block.endsAt) - Date.parse(block.startsAt)) / 60_000, 0);
    expect(proposedMinutes).toBe(60);
    expect(JSON.stringify(response.proposal.changes)).not.toContain(ids.laterMathBlock);
  });

  it("rejects reuse of an event id with different state", async () => {
    const service = new IncompleteReplanService();
    await service.createProposal(request(), "user-1");
    const changed = request();
    changed.sourceFingerprint = "c".repeat(64);
    await expect(service.createProposal(changed, "user-1")).rejects.toBeInstanceOf(IdempotencyConflictError);
  });
});

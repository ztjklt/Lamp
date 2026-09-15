import { describe, expect, it } from "vitest";
import { StateSnapshotSchema, type StateSnapshot } from "../src/agent/state/StateSnapshot.js";
import { ReplanningEngine } from "../src/planning/ReplanningEngine.js";
import { SchedulingEngine } from "../src/planning/SchedulingEngine.js";
import { InMemoryPlanRevisionRepository } from "../src/infrastructure/repositories/InMemoryPlanRevisionRepository.js";
import { FixedClock } from "../src/infrastructure/clock/FixedClock.js";
import { fixtureIds, makeStateSnapshot } from "./fixtures/StateFixture.js";

const ids = {
  event1: "00000000-0000-4000-8000-000000000601",
  event2: "00000000-0000-4000-8000-000000000602",
  calendar: "00000000-0000-4000-8000-000000000603",
  mathBlock: "00000000-0000-4000-8000-000000000604",
  englishTask: "00000000-0000-4000-8000-000000000605",
  englishBlock: "00000000-0000-4000-8000-000000000606",
  plan: "00000000-0000-4000-8000-000000000607",
};

function createEngine(repository = new InMemoryPlanRevisionRepository()) {
  return {
    repository,
    replanning: new ReplanningEngine(
      new SchedulingEngine(),
      repository,
      new FixedClock("2026-09-08T11:45:00Z"),
    ),
  };
}

function incompleteState(): StateSnapshot {
  const state = StateSnapshotSchema.parse(makeStateSnapshot());
  state.now = "2026-09-08T11:45:00Z";
  state.activeTasks[0]!.remainingMinutes = 30;
  state.activeTasks[0]!.preferredPeriods = ["evening"];
  state.activeTasks.push({
    ...structuredClone(state.activeTasks[0]!),
    id: ids.englishTask,
    title: "复习英语",
    remainingMinutes: 50,
    estimatedMinutes: 50,
  });
  state.schedule.push(
    {
      id: ids.mathBlock,
      taskId: fixtureIds.task,
      title: "复习高数",
      startsAt: "2026-09-08T11:00:00Z",
      endsAt: "2026-09-08T12:00:00Z",
      kind: "focus",
      state: "active",
      locked: false,
      provenance: "plan-v1",
      reasonCodes: ["USER_REQUESTED_PLAN"],
      revision: 8,
    },
    {
      id: ids.englishBlock,
      taskId: ids.englishTask,
      title: "复习英语",
      startsAt: "2026-09-08T12:10:00Z",
      endsAt: "2026-09-08T13:00:00Z",
      kind: "focus",
      state: "planned",
      locked: false,
      provenance: "plan-v1",
      reasonCodes: ["USER_REQUESTED_PLAN"],
      revision: 8,
    },
  );
  return StateSnapshotSchema.parse(state);
}

describe("ReplanningEngine", () => {
  it("moves only the incomplete task and preserves the following task", async () => {
    const setup = createEngine();
    const state = incompleteState();
    const result = await setup.replanning.replan({
      planId: ids.plan,
      state,
      event: {
        eventId: ids.event1,
        userId: "user-1",
        occurredAt: "2026-09-08T11:45:00Z",
        type: "TASK_INCOMPLETE",
        payload: { taskId: fixtureIds.task, additionalMinutes: 30 },
      },
      candidateLimit: 3,
      slotGranularityMinutes: 10,
      maximumDailyFocusMinutes: 360,
    });

    expect(result.status).toBe("proposal");
    if (result.status !== "proposal") return;
    expect(result.decision).toMatchObject({ action: "replan", scope: "local" });
    expect(result.candidate.blocks).toHaveLength(1);
    expect(result.candidate.blocks[0]).toMatchObject({ taskId: fixtureIds.task, replacesBlockId: ids.mathBlock });
    expect(Date.parse(result.candidate.blocks[0]!.startsAt)).toBeGreaterThanOrEqual(Date.parse("2026-09-08T13:00:00Z"));
    expect(result.revision.changes).toHaveLength(1);
    expect(result.revision.changes[0]).toMatchObject({ type: "MOVE", previousBlockId: ids.mathBlock });
    expect(JSON.stringify(result.revision.changes)).not.toContain(ids.englishBlock);
    expect(result.revision).toMatchObject({ revision: 1, risk: "low", requiresConfirmation: false, status: "proposed" });
    expect(await setup.repository.list(ids.plan)).toHaveLength(1);
  });

  it("keeps an existing valid placement when stability beats unnecessary reshuffling", async () => {
    const state = StateSnapshotSchema.parse(makeStateSnapshot());
    state.activeTasks[0]!.remainingMinutes = 60;
    state.activeTasks[0]!.preferredPeriods = ["evening"];
    state.schedule.push({
      id: ids.mathBlock,
      taskId: fixtureIds.task,
      title: "复习高数",
      startsAt: "2026-09-08T10:00:00Z",
      endsAt: "2026-09-08T11:00:00Z",
      kind: "focus",
      state: "planned",
      locked: false,
      provenance: "plan-v1",
      reasonCodes: ["USER_REQUESTED_PLAN"],
      revision: 8,
    });
    const setup = createEngine();
    const result = await setup.replanning.replan({
      planId: ids.plan,
      state: StateSnapshotSchema.parse(state),
      event: {
        eventId: ids.event1,
        userId: "user-1",
        occurredAt: "2026-09-08T08:00:00Z",
        type: "USER_REQUEST_REPLAN",
        payload: { scope: "day", taskIds: [fixtureIds.task] },
      },
    });

    expect(result.status).toBe("proposal");
    if (result.status !== "proposal") return;
    expect(result.revision.scheduleChangeCost).toBe(0);
    expect(result.revision.changes).toEqual([expect.objectContaining({ type: "UNCHANGED", previousBlockId: ids.mathBlock })]);
    expect(result.candidate.blocks[0]).toMatchObject({ startsAt: "2026-09-08T10:00:00Z", endsAt: "2026-09-08T11:00:00Z" });
  });

  it("expands local scope only when the local window has no feasible capacity", async () => {
    const state = StateSnapshotSchema.parse(makeStateSnapshot());
    state.activeTasks[0]!.availableWindows = [{ start: "2026-09-08T13:00:00Z", end: "2026-09-08T15:00:00Z" }];
    const setup = createEngine();
    const result = await setup.replanning.replan({
      planId: ids.plan,
      state: StateSnapshotSchema.parse(state),
      event: {
        eventId: ids.event1,
        userId: "user-1",
        occurredAt: "2026-09-08T08:00:00Z",
        type: "USER_REQUEST_REPLAN",
        payload: { scope: "local", taskIds: [fixtureIds.task] },
      },
    });

    expect(result.status).toBe("proposal");
    if (result.status !== "proposal") return;
    expect(result.revision.scope).toBe("day");
    expect(result.revision.risk).toBe("medium");
    expect(result.revision.requiresConfirmation).toBe(true);
    expect(result.diagnostics).toEqual(expect.arrayContaining(["local:no_feasible_plan", "day:success"]));
  });

  it("treats a newly added event as protected even before it appears in the snapshot", async () => {
    const state = StateSnapshotSchema.parse(makeStateSnapshot());
    state.now = "2026-09-08T10:00:00Z";
    state.activeTasks[0]!.remainingMinutes = 60;
    state.schedule.push({
      id: ids.mathBlock,
      taskId: fixtureIds.task,
      title: "复习高数",
      startsAt: "2026-09-08T11:00:00Z",
      endsAt: "2026-09-08T12:00:00Z",
      kind: "focus",
      state: "planned",
      locked: false,
      provenance: "plan-v1",
      reasonCodes: ["USER_REQUESTED_PLAN"],
      revision: 8,
    });
    const setup = createEngine();
    const eventRange = { start: "2026-09-08T11:15:00Z", end: "2026-09-08T11:45:00Z" };
    const result = await setup.replanning.replan({
      state: StateSnapshotSchema.parse(state),
      event: {
        eventId: ids.event2,
        userId: "user-1",
        occurredAt: "2026-09-08T10:00:00Z",
        type: "EVENT_ADDED",
        payload: { calendarEventId: ids.calendar, range: eventRange },
      },
    });

    expect(result.status).toBe("proposal");
    if (result.status !== "proposal") return;
    expect(result.candidate.blocks.every((block) =>
      Date.parse(block.endsAt) <= Date.parse(eventRange.start) || Date.parse(block.startsAt) >= Date.parse(eventRange.end))).toBe(true);
    expect(result.revision.scheduleChangeCost).toBeGreaterThan(0);
  });

  it("appends immutable linked revisions instead of overwriting history", async () => {
    const state = StateSnapshotSchema.parse(makeStateSnapshot());
    state.activeTasks[0]!.remainingMinutes = 60;
    state.activeTasks[0]!.preferredPeriods = ["evening"];
    state.schedule.push({
      id: ids.mathBlock,
      taskId: fixtureIds.task,
      title: "复习高数",
      startsAt: "2026-09-08T10:00:00Z",
      endsAt: "2026-09-08T11:00:00Z",
      kind: "focus",
      state: "planned",
      locked: false,
      provenance: "plan-v1",
      reasonCodes: ["USER_REQUESTED_PLAN"],
      revision: 8,
    });
    const parsed = StateSnapshotSchema.parse(state);
    const setup = createEngine();
    const first = await setup.replanning.replan({
      planId: ids.plan,
      state: parsed,
      event: {
        eventId: ids.event1,
        userId: "user-1",
        occurredAt: "2026-09-08T08:00:00Z",
        type: "USER_REQUEST_REPLAN",
        payload: { scope: "day", taskIds: [fixtureIds.task] },
      },
    });
    const second = await setup.replanning.replan({
      planId: ids.plan,
      state: parsed,
      event: {
        eventId: ids.event2,
        userId: "user-1",
        occurredAt: "2026-09-08T08:05:00Z",
        type: "USER_REQUEST_REPLAN",
        payload: { scope: "day", taskIds: [fixtureIds.task] },
      },
    });

    expect(first.status).toBe("proposal");
    expect(second.status).toBe("proposal");
    if (first.status !== "proposal" || second.status !== "proposal") return;
    expect(second.revision).toMatchObject({ revision: 2, previousRevisionId: first.revision.revisionId });
    const history = await setup.repository.list(ids.plan);
    expect(history.map((revision) => revision.revision)).toEqual([1, 2]);
  });
});

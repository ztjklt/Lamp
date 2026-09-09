import { describe, expect, it } from "vitest";
import { StateEngine } from "../src/agent/state/StateEngine.js";
import type { UserState } from "../src/agent/state/StateModels.js";
import type {
  StateReadRepository,
  StateSourceData,
  UserRepository,
} from "../src/domain/repositories/StateRepositories.js";
import { LampError } from "../src/errors/LampError.js";
import { FixedClock } from "../src/infrastructure/clock/FixedClock.js";
import {
  InMemoryStateRepository,
  InMemoryStateSnapshotRepository,
} from "../src/infrastructure/repositories/InMemoryStateRepositories.js";
import { TimeZoneService } from "../src/infrastructure/time/TimeZoneService.js";

const userId = "user-1";
const taskId = "00000000-0000-4000-8000-000000000010";
const blockId = "00000000-0000-4000-8000-000000000020";
const outsideBlockId = "00000000-0000-4000-8000-000000000021";
const eventId = "00000000-0000-4000-8000-000000000030";
const constraintId = "00000000-0000-4000-8000-000000000040";
const snapshotId = "00000000-0000-4000-8000-000000000050";

const user: UserState = {
  id: userId,
  timezone: "Asia/Singapore",
  locale: "zh-CN",
  version: 4,
};

function sourceData(userVersion = 4): StateSourceData {
  return {
    userVersion,
    sourceRevision: 12,
    goals: [],
    activeTasks: [{
      id: taskId,
      goalId: null,
      title: "复习高数",
      detail: "",
      importance: 5,
      deadline: "2026-09-09T01:00:00Z",
      estimatedMinutes: 120,
      remainingMinutes: 120,
      isPaused: false,
      isSplittable: true,
      minimumSessionMinutes: 20,
      maximumSessionMinutes: 90,
      preferredPeriods: ["afternoon"],
      dependencyIds: [],
      availableWindows: [],
      version: 1,
    }],
    schedule: [
      {
        id: blockId,
        taskId: null,
        title: "社团活动",
        startsAt: "2026-09-08T11:00:00Z",
        endsAt: "2026-09-08T13:00:00Z",
        kind: "fixed",
        state: "planned",
        locked: true,
        provenance: "fixture",
        reasonCodes: ["FIXED_EVENT_CONFLICT"],
        revision: 12,
      },
      {
        id: outsideBlockId,
        taskId: null,
        title: "范围外事件",
        startsAt: "2026-09-12T00:00:00Z",
        endsAt: "2026-09-12T01:00:00Z",
        kind: "fixed",
        state: "planned",
        locked: true,
        provenance: "fixture",
        reasonCodes: [],
        revision: 12,
      },
    ],
    upcomingEvents: [{
      id: eventId,
      externalId: "calendar-1",
      provider: "fixture-calendar",
      title: "社团活动",
      startsAt: "2026-09-08T11:00:00Z",
      endsAt: "2026-09-08T13:00:00Z",
      allDay: false,
      locked: true,
      status: "confirmed",
      version: 2,
    }],
    preferences: {
      userId,
      preferredSleepTime: "23:30",
      preferredWakeTime: "08:00",
      defaultReminderMinutes: 5,
      preferredFocusMinutes: 50,
      preferredBreakMinutes: 10,
      morningStudyPreference: 0.4,
      eveningStudyPreference: 0.8,
      version: 3,
    },
    energy: null,
    lockedConstraints: [{
      id: constraintId,
      type: "FIXED_EVENT_PROTECTION",
      parameters: {},
      source: "system",
      locked: true,
      version: 1,
    }],
  };
}

function idGenerator() {
  return { next: () => snapshotId };
}

describe("StateEngine", () => {
  it("builds, validates, freezes and persists an independent state snapshot", async () => {
    const source = new InMemoryStateRepository([{ user, state: sourceData() }]);
    const snapshots = new InMemoryStateSnapshotRepository();
    const engine = new StateEngine(
      source,
      source,
      snapshots,
      new FixedClock("2026-09-08T02:00:00Z"),
      idGenerator(),
      new TimeZoneService(),
      { defaultHorizonDays: 1 },
    );

    const snapshot = await engine.buildSnapshot({ userId });

    expect(snapshot.now).toBe("2026-09-08T02:00:00Z");
    expect(snapshot.planningHorizon).toEqual({
      start: "2026-09-08T02:00:00Z",
      end: "2026-09-08T16:00:00Z",
    });
    expect(snapshot.schedule.map((block) => block.id)).toEqual([blockId]);
    expect(Object.isFrozen(snapshot)).toBe(true);
    expect(Object.isFrozen(snapshot.activeTasks)).toBe(true);
    expect(await snapshots.getById(snapshotId)).toEqual(snapshot);
  });

  it("fails closed if a repository returns another user's record", async () => {
    const wrongUserRepository: UserRepository = {
      getById: async () => ({ ...user, id: "user-2" }),
    };
    const engine = new StateEngine(
      wrongUserRepository,
      { readForSnapshot: async () => sourceData() },
      new InMemoryStateSnapshotRepository(),
      new FixedClock("2026-09-08T02:00:00Z"),
      idGenerator(),
      new TimeZoneService(),
      { defaultHorizonDays: 1 },
    );

    await expect(engine.buildSnapshot({ userId })).rejects.toMatchObject({ code: "AUTH_ERROR" });
  });

  it("retries a moving user revision and then reports stale state", async () => {
    const users: UserRepository = { getById: async () => user };
    let reads = 0;
    const changingState: StateReadRepository = {
      readForSnapshot: async () => {
        reads += 1;
        return sourceData(user.version + reads);
      },
    };
    const engine = new StateEngine(
      users,
      changingState,
      new InMemoryStateSnapshotRepository(),
      new FixedClock("2026-09-08T02:00:00Z"),
      idGenerator(),
      new TimeZoneService(),
      { defaultHorizonDays: 1, maximumConsistencyAttempts: 2 },
    );

    await expect(engine.buildSnapshot({ userId })).rejects.toMatchObject({
      code: "STALE_STATE",
      retryable: true,
    } satisfies Partial<LampError>);
    expect(reads).toBe(2);
  });
});

import { StateSnapshotSchema, type StateSnapshot } from "../../agent/state/StateSnapshot.js";
import { deterministicUuid } from "../../planning/PlanningUtilities.js";

type FixtureName = "student-normal-day" | "exam-tomorrow" | "overloaded-day" | "late-wake-up" |
  "task-missed" | "new-urgent-task" | "locked-class-conflict";

export function StudentNormalDay(variant = 0): StateSnapshot {
  return makeFixture("student-normal-day", variant);
}

export function ExamTomorrow(variant = 0): StateSnapshot {
  const state = makeFixture("exam-tomorrow", variant);
  state.activeTasks[0]!.title = "复习明天的考试";
  state.activeTasks[0]!.deadline = [`2026-09-08T11:00:00Z`, `2026-09-08T11:30:00Z`, `2026-09-08T12:00:00Z`][variant % 3]!;
  state.goals[0]!.deadline = state.activeTasks[0]!.deadline;
  return StateSnapshotSchema.parse(state);
}

export function OverloadedDay(variant = 0): StateSnapshot {
  const state = makeFixture("overloaded-day", variant);
  state.energy = {
    level: 0.25,
    source: "user_explicit",
    capturedAt: state.now,
    expiresAt: "2026-09-08T12:00:00Z",
  };
  state.activeTasks[0]!.remainingMinutes = 120;
  state.activeTasks[0]!.estimatedMinutes = 120;
  return StateSnapshotSchema.parse(state);
}

export function LateWakeUp(variant = 0): StateSnapshot {
  const state = makeFixture("late-wake-up", variant);
  state.now = "2026-09-08T10:00:00Z";
  state.capturedAt = state.now;
  return StateSnapshotSchema.parse(state);
}

export function TaskMissed(variant = 0): StateSnapshot {
  const state = makeFixture("task-missed", variant);
  state.now = "2026-09-08T10:45:00Z";
  state.capturedAt = state.now;
  state.activeTasks[0]!.remainingMinutes = 30 + (variant % 3) * 10;
  state.activeTasks[0]!.estimatedMinutes = 60;
  state.schedule.push({
    id: deterministicUuid("task-missed", String(variant), "focus-block"),
    taskId: state.activeTasks[0]!.id,
    title: state.activeTasks[0]!.title,
    startsAt: "2026-09-08T10:00:00Z",
    endsAt: "2026-09-08T11:00:00Z",
    kind: "focus",
    state: "active",
    locked: false,
    provenance: "eval-plan-v1",
    reasonCodes: ["USER_REQUESTED_PLAN"],
    revision: 1,
  });
  return StateSnapshotSchema.parse(state);
}

export function NewUrgentTask(variant = 0): StateSnapshot {
  const state = makeFixture("new-urgent-task", variant);
  state.activeTasks[0]!.importance = 5;
  state.activeTasks[0]!.deadline = "2026-09-08T12:00:00Z";
  return StateSnapshotSchema.parse(state);
}

export function LockedClassConflict(variant = 0): StateSnapshot {
  const state = makeFixture("locked-class-conflict", variant);
  state.upcomingEvents[0]!.title = `锁定课程 ${variant + 1}`;
  return StateSnapshotSchema.parse(state);
}

export function StablePlan(variant = 0): StateSnapshot {
  const state = makeFixture("student-normal-day", 100 + variant);
  state.activeTasks[0]!.remainingMinutes = 60;
  state.activeTasks[0]!.estimatedMinutes = 60;
  state.schedule.push({
    id: deterministicUuid("stable-plan", String(variant), "focus-block"),
    taskId: state.activeTasks[0]!.id,
    title: state.activeTasks[0]!.title,
    startsAt: "2026-09-08T10:00:00Z",
    endsAt: "2026-09-08T11:00:00Z",
    kind: "focus",
    state: "planned",
    locked: false,
    provenance: "eval-plan-v1",
    reasonCodes: ["USER_REQUESTED_PLAN"],
    revision: 1,
  });
  return StateSnapshotSchema.parse(state);
}

function makeFixture(name: FixtureName, variant: number): StateSnapshot {
  const userId = "eval-user";
  const taskId = deterministicUuid(name, String(variant), "task");
  const goalId = deterministicUuid(name, String(variant), "goal");
  return StateSnapshotSchema.parse({
    snapshotId: deterministicUuid(name, String(variant), "snapshot"),
    userId,
    sourceRevision: 1,
    capturedAt: "2026-09-08T08:00:00Z",
    now: "2026-09-08T08:00:00Z",
    timezone: "Asia/Singapore",
    user: { id: userId, timezone: "Asia/Singapore", locale: "zh-CN", version: 1 },
    goals: [{
      id: goalId,
      parentId: null,
      title: "完成本周学习目标",
      detail: "评测夹具",
      importance: 4,
      deadline: "2026-09-08T15:00:00Z",
      status: "active",
      version: 1,
    }],
    activeTasks: [{
      id: taskId,
      goalId,
      title: "复习高数",
      detail: "评测任务",
      importance: 4,
      deadline: "2026-09-08T15:00:00Z",
      estimatedMinutes: 60,
      remainingMinutes: 60,
      isPaused: false,
      isSplittable: true,
      minimumSessionMinutes: 20,
      maximumSessionMinutes: 90,
      preferredPeriods: [variant % 2 === 0 ? "evening" : "afternoon"],
      dependencyIds: [],
      availableWindows: [],
      version: 1,
    }],
    schedule: [],
    upcomingEvents: [{
      id: deterministicUuid(name, String(variant), "calendar-event"),
      externalId: `eval-class-${variant}`,
      provider: "eval-calendar",
      title: "固定课程",
      startsAt: "2026-09-08T09:00:00Z",
      endsAt: "2026-09-08T10:00:00Z",
      allDay: false,
      locked: true,
      status: "confirmed",
      version: 1,
    }],
    preferences: {
      userId,
      preferredSleepTime: "23:30",
      preferredWakeTime: "07:30",
      defaultReminderMinutes: 5,
      preferredFocusMinutes: 50,
      preferredBreakMinutes: 10,
      morningStudyPreference: 0.4,
      eveningStudyPreference: 0.8,
      version: 1,
    },
    energy: null,
    planningHorizon: { start: "2026-09-08T08:00:00Z", end: "2026-09-08T16:00:00Z" },
    lockedConstraints: [],
  });
}

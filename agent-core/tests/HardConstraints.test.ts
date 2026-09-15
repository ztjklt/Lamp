import { describe, expect, it } from "vitest";
import { PlanningRequestSchema, type ProposedScheduleBlock, type RawScheduleCandidate } from "../src/planning/PlanningTypes.js";
import {
  AvailableWindowConstraint,
  BeforeDeadlineConstraint,
  DependencyOrderConstraint,
  FixedEventProtectionConstraint,
  LockedEventImmutableConstraint,
  MaximumWorkloadConstraint,
  MinimumDurationConstraint,
  NoOverlapConstraint,
  SleepBoundaryConstraint,
  UserBlockedTimeConstraint,
} from "../src/planning/constraints/HardConstraints.js";
import { makeStateSnapshot, fixtureIds } from "./fixtures/StateFixture.js";

const ids = {
  proposal1: "00000000-0000-4000-8000-000000000201",
  proposal2: "00000000-0000-4000-8000-000000000202",
  dependency: "00000000-0000-4000-8000-000000000203",
};

function makeRequest() {
  const state = structuredClone(makeStateSnapshot());
  state.activeTasks[0]!.availableWindows = [{ start: "2026-09-08T10:00:00Z", end: "2026-09-08T12:00:00Z" }];
  return PlanningRequestSchema.parse({
    state,
    taskIds: [fixtureIds.task],
    horizon: state.planningHorizon,
    scope: "day",
    candidateLimit: 3,
    slotGranularityMinutes: 10,
    maximumDailyFocusMinutes: 360,
  });
}

function block(start: string, end: string, id = ids.proposal1, taskId = fixtureIds.task): ProposedScheduleBlock {
  return { id, taskId, title: "test", startsAt: start, endsAt: end, replacesBlockId: null, reasonCodes: ["TEST"] };
}

function candidate(...blocks: ProposedScheduleBlock[]): RawScheduleCandidate {
  return { id: "00000000-0000-4000-8000-000000000204", blocks, changedExistingBlocks: 0 };
}

describe("Phase 4 hard constraints", () => {
  it("detects NO_OVERLAP", () => {
    const result = new NoOverlapConstraint().validate(candidate(
      block("2026-09-08T10:00:00Z", "2026-09-08T11:00:00Z"),
      block("2026-09-08T10:30:00Z", "2026-09-08T11:30:00Z", ids.proposal2),
    ), makeRequest());
    expect(result[0]?.code).toBe("NO_OVERLAP");
  });

  it("detects LOCKED_EVENT_IMMUTABLE", () => {
    const value = block("2026-09-08T10:00:00Z", "2026-09-08T11:00:00Z");
    value.replacesBlockId = fixtureIds.block;
    expect(new LockedEventImmutableConstraint().validate(candidate(value), makeRequest())[0]?.code).toBe("LOCKED_EVENT_IMMUTABLE");
  });

  it("detects BEFORE_DEADLINE", () => {
    expect(new BeforeDeadlineConstraint().validate(candidate(
      block("2026-09-08T23:30:00Z", "2026-09-09T02:00:00Z"),
    ), makeRequest())[0]?.code).toBe("BEFORE_DEADLINE");
  });

  it("detects DEPENDENCY_ORDER", () => {
    const request = makeRequest();
    request.state.activeTasks.push({
      ...structuredClone(request.state.activeTasks[0]!),
      id: ids.dependency,
      title: "dependency",
      remainingMinutes: 50,
      dependencyIds: [],
    });
    request.state.activeTasks[0]!.dependencyIds = [ids.dependency];
    request.taskIds.push(ids.dependency);
    const result = new DependencyOrderConstraint().validate(candidate(
      block("2026-09-08T10:00:00Z", "2026-09-08T10:50:00Z"),
      block("2026-09-08T11:00:00Z", "2026-09-08T11:50:00Z", ids.proposal2, ids.dependency),
    ), request);
    expect(result[0]?.code).toBe("DEPENDENCY_ORDER");
  });

  it("detects MINIMUM_DURATION", () => {
    expect(new MinimumDurationConstraint().validate(candidate(
      block("2026-09-08T10:00:00Z", "2026-09-08T10:10:00Z"),
    ), makeRequest())[0]?.code).toBe("MINIMUM_DURATION");
  });

  it("detects AVAILABLE_WINDOW", () => {
    expect(new AvailableWindowConstraint().validate(candidate(
      block("2026-09-08T12:00:00Z", "2026-09-08T13:00:00Z"),
    ), makeRequest())[0]?.code).toBe("AVAILABLE_WINDOW");
  });

  it("detects SLEEP_BOUNDARY", () => {
    expect(new SleepBoundaryConstraint().validate(candidate(
      block("2026-09-08T16:00:00Z", "2026-09-08T17:00:00Z"),
    ), makeRequest())[0]?.code).toBe("SLEEP_BOUNDARY");
  });

  it("detects FIXED_EVENT_PROTECTION", () => {
    expect(new FixedEventProtectionConstraint().validate(candidate(
      block("2026-09-08T09:10:00Z", "2026-09-08T09:50:00Z"),
    ), makeRequest())[0]?.code).toBe("FIXED_EVENT_PROTECTION");
  });

  it("detects USER_BLOCKED_TIME", () => {
    expect(new UserBlockedTimeConstraint().validate(candidate(
      block("2026-09-08T18:10:00Z", "2026-09-08T18:50:00Z"),
    ), makeRequest())[0]?.code).toBe("USER_BLOCKED_TIME");
  });

  it("detects MAXIMUM_WORKLOAD", () => {
    expect(new MaximumWorkloadConstraint().validate(candidate(
      block("2026-09-08T08:00:00Z", "2026-09-08T14:40:00Z"),
    ), makeRequest())[0]?.code).toBe("MAXIMUM_WORKLOAD");
  });
});

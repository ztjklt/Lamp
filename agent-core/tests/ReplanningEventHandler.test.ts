import { describe, expect, it } from "vitest";
import { EventBus } from "../src/events/EventBus.js";
import { ReplanningEventHandler } from "../src/events/ReplanningEventHandler.js";
import { ReplanningEngine } from "../src/planning/ReplanningEngine.js";
import { SchedulingEngine } from "../src/planning/SchedulingEngine.js";
import { StateEngine } from "../src/agent/state/StateEngine.js";
import { InMemoryPlanRevisionRepository } from "../src/infrastructure/repositories/InMemoryPlanRevisionRepository.js";
import { InMemoryStateRepository, InMemoryStateSnapshotRepository } from "../src/infrastructure/repositories/InMemoryStateRepositories.js";
import { FixedClock } from "../src/infrastructure/clock/FixedClock.js";
import { TimeZoneService } from "../src/infrastructure/time/TimeZoneService.js";
import type { ReplanningResult } from "../src/planning/ReplanningTypes.js";
import { fixtureIds, makeStateSnapshot } from "./fixtures/StateFixture.js";

describe("ReplanningEventHandler", () => {
  it("runs Event -> StateSnapshot -> ReplanningPolicy -> SchedulingEngine -> Proposal", async () => {
    const fixture = makeStateSnapshot();
    const source = new InMemoryStateRepository([{
      user: fixture.user,
      state: {
        userVersion: fixture.user.version,
        sourceRevision: fixture.sourceRevision,
        goals: fixture.goals,
        activeTasks: fixture.activeTasks,
        schedule: fixture.schedule,
        upcomingEvents: fixture.upcomingEvents,
        preferences: fixture.preferences,
        energy: fixture.energy,
        lockedConstraints: fixture.lockedConstraints,
      },
    }]);
    const clock = new FixedClock("2026-09-08T08:00:00Z");
    let id = 700;
    const stateEngine = new StateEngine(
      source,
      source,
      new InMemoryStateSnapshotRepository(),
      clock,
      { next: () => `00000000-0000-4000-8000-${String(id++).padStart(12, "0")}` },
      new TimeZoneService(),
      { defaultHorizonDays: 1 },
    );
    const replanning = new ReplanningEngine(
      new SchedulingEngine(),
      new InMemoryPlanRevisionRepository(),
      clock,
    );
    let received: ReplanningResult | undefined;
    const handler = new ReplanningEventHandler(stateEngine, replanning, async (_event, result) => {
      received = result;
    }, 1);
    const bus = new EventBus();
    bus.subscribe("USER_REQUEST_REPLAN", (event) => handler.handle(event));

    await bus.publish({
      eventId: "00000000-0000-4000-8000-000000000701",
      userId: "user-1",
      occurredAt: "2026-09-08T08:00:00Z",
      type: "USER_REQUEST_REPLAN",
      payload: { scope: "day", taskIds: [fixtureIds.task] },
    });

    expect(received).toMatchObject({
      status: "proposal",
      revision: { status: "proposed", baseStateRevision: fixture.sourceRevision },
    });
  });
});

import { describe, expect, it } from "vitest";
import { EventBus } from "../src/events/EventBus.js";
import { fixtureIds } from "./fixtures/StateFixture.js";

function event() {
  return {
    eventId: "00000000-0000-4000-8000-000000000520",
    userId: "user-1",
    occurredAt: "2026-09-08T08:30:00Z",
    type: "TASK_OVERDUE",
    payload: { taskId: fixtureIds.task },
  };
}

describe("EventBus", () => {
  it("delivers a valid event once and suppresses duplicate delivery", async () => {
    const bus = new EventBus();
    let deliveries = 0;
    bus.subscribe("TASK_OVERDUE", async (value) => {
      deliveries += 1;
      expect(Object.isFrozen(value)).toBe(true);
    });
    expect(await bus.publish(event())).toBe(true);
    expect(await bus.publish(event())).toBe(false);
    expect(deliveries).toBe(1);
  });

  it("allows retry when a handler fails", async () => {
    const bus = new EventBus();
    let attempts = 0;
    bus.subscribe("*", async () => {
      attempts += 1;
      if (attempts === 1) throw new Error("fixture failure");
    });
    await expect(bus.publish(event())).rejects.toThrow("fixture failure");
    expect(await bus.publish(event())).toBe(true);
    expect(attempts).toBe(2);
  });
});

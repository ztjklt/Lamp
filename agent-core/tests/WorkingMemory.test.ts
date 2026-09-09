import { describe, expect, it } from "vitest";
import { WorkingMemory } from "../src/agent/memory/WorkingMemory.js";
import { FixedClock } from "../src/infrastructure/clock/FixedClock.js";
import { InMemoryWorkingMemoryStore } from "../src/infrastructure/repositories/InMemoryMemoryRepositories.js";

const run1 = "00000000-0000-4000-8000-000000000301";
const run2 = "00000000-0000-4000-8000-000000000302";

function harness() {
  const clock = new FixedClock("2026-09-08T08:00:00Z");
  let id = 310;
  const memory = new WorkingMemory(new InMemoryWorkingMemoryStore(), clock, {
    next: () => `00000000-0000-4000-8000-${String(id++).padStart(12, "0")}`,
  });
  return { memory, clock };
}

describe("WorkingMemory", () => {
  it("isolates values by user, session, and run", async () => {
    const { memory } = harness();
    await memory.put({ userId: "user-1", sessionId: "session-1", runId: run1, key: "current_goal", value: { goal: "math" } });
    await expect(memory.listForRun("user-1", "session-1", run1)).resolves.toHaveLength(1);
    await expect(memory.listForRun("user-1", "session-2", run1)).resolves.toEqual([]);
    await expect(memory.listForRun("user-2", "session-1", run1)).resolves.toEqual([]);
    await expect(memory.listForRun("user-1", "session-1", run2)).resolves.toEqual([]);
  });

  it("automatically clears entries at expiration", async () => {
    const { memory, clock } = harness();
    await memory.put({ userId: "user-1", sessionId: "session-1", runId: run1, key: "current_goal", value: { goal: "math" }, ttlMinutes: 5 });
    clock.advance({ minutes: 5 });
    await expect(memory.listForRun("user-1", "session-1", run1)).resolves.toEqual([]);
  });

  it("updates a run-scoped key without growing hidden history", async () => {
    const { memory, clock } = harness();
    const first = await memory.put({ userId: "user-1", sessionId: "session-1", runId: run1, key: "current_goal", value: { goal: "math" } });
    clock.advance({ minutes: 1 });
    const second = await memory.put({ userId: "user-1", sessionId: "session-1", runId: run1, key: "current_goal", value: { goal: "english" } });
    expect(second.workingMemoryId).toBe(first.workingMemoryId);
    await expect(memory.listForRun("user-1", "session-1", run1)).resolves.toMatchObject([{ value: { goal: "english" } }]);
  });
});

import { describe, expect, it } from "vitest";
import { AgentRun, type AgentRunRuntime } from "../src/agent/orchestrator/AgentRun.js";
import { LampError } from "../src/errors/LampError.js";
import { FixedClock } from "../src/infrastructure/clock/FixedClock.js";

const ids = [
  "00000000-0000-4000-8000-000000000001",
  "00000000-0000-4000-8000-000000000002",
  "00000000-0000-4000-8000-000000000003",
];

function runtime(): AgentRunRuntime {
  let index = 0;
  return {
    clock: new FixedClock("2026-09-08T00:00:00.000Z"),
    ids: { next: () => ids[index++] ?? "00000000-0000-4000-8000-000000000099" },
  };
}

describe("AgentRun", () => {
  it("captures replayable metadata and aggregates model usage", () => {
    const run = AgentRun.start({
      userId: "user-1",
      sessionId: "session-1",
      requestId: "request-1",
      initialInput: "安排明天下午复习高数",
    }, runtime());

    run.setIntent({
      intent: "plan_schedule",
      confidence: 0.95,
      entities: {},
      requiresClarification: false,
    });
    run.addModelCall({
      id: "00000000-0000-4000-8000-000000000003",
      provider: "deepseek",
      model: "deepseek-v4-flash",
      startedAt: "2026-09-08T00:00:00.000Z",
      endedAt: "2026-09-08T00:00:00.100Z",
      status: "succeeded",
      inputTokens: 100,
      outputTokens: 20,
      cacheHitTokens: 40,
      cacheMissTokens: 60,
      latencyMs: 100,
      estimatedCost: 0.001,
    });
    run.succeed({ proposalId: "proposal-1" });

    const snapshot = run.snapshot();
    expect(snapshot.finalStatus).toBe("succeeded");
    expect(snapshot.tokenUsage).toEqual({ input: 100, output: 20, cacheHit: 40, cacheMiss: 60 });
    expect(snapshot.estimatedCost).toBe(0.001);
    expect(JSON.stringify(snapshot)).not.toContain("chainOfThought");
  });

  it("cannot mutate a finished run", () => {
    const run = AgentRun.start({
      userId: "user-1",
      sessionId: "session-1",
      requestId: "request-1",
      initialInput: "hello",
    }, runtime());
    run.succeed({ ok: true });

    expect(() => run.setStateSnapshot("00000000-0000-4000-8000-000000000003"))
      .toThrowError(LampError);
  });
});

import { describe, expect, it } from "vitest";
import { DebugApi } from "../src/debug/DebugApi.js";
import { LocalDebugHarness } from "../src/debug/LocalDebugHarness.js";
import { ReplayBundleSchema } from "../src/debug/Replay.js";
import { StudentNormalDay } from "../src/evals/fixtures/EvalFixtures.js";

function request(requestId = "debug-request-1", input = "安排复习高数") {
  return {
    context: {
      userId: "eval-user",
      sessionId: "debug-session",
      requestId,
      timezone: "Asia/Singapore",
      locale: "zh-CN",
      automationLevel: 0 as const,
      authentication: {
        subject: "eval-user",
        scopes: ["state:read", "activity:read", "agent_runs:read"],
      },
    },
    input,
    horizonDays: 1,
  };
}

function api(harness: LocalDebugHarness, enabled = true, environment: "development" | "test" | "production" = "test") {
  return new DebugApi(
    { enabled, environment },
    harness,
    harness.runs,
    harness.snapshots,
    harness.audits,
  );
}

describe("Phase 9 debug harness", () => {
  it("runs the real orchestrator offline and emits an ordered, redacted trace", async () => {
    const artifact = await new LocalDebugHarness().run(request());
    expect(artifact.response).toMatchObject({ status: "succeeded", proposal: { candidates: expect.any(Array) } });
    const types = artifact.trace.events.map((event) => event.type);
    const models = types.map((type, index) => type === "LLMCall" ? index : -1).filter((index) => index >= 0);
    expect(types).toEqual(expect.arrayContaining([
      "AgentStart", "StateBuilt", "LLMCall", "PlannerStarted", "CandidateGenerated",
      "CandidateScored", "PlanValidated", "AgentFinished",
    ]));
    expect(types.indexOf("PlanValidated")).toBeLessThan(models[1]!);
    expect(JSON.stringify(artifact.trace)).not.toContain(request().input);
    expect(JSON.stringify(artifact.trace)).not.toContain("reasoningContent");
  });

  it("replays captured model outputs and matches the normalized final result", async () => {
    const harness = new LocalDebugHarness();
    const artifact = await harness.run(request("replay-request"));
    await expect(harness.replay(artifact.replayBundle)).resolves.toMatchObject({
      replayId: artifact.replayBundle.replayId,
      matched: true,
    });
  });

  it("orders tool selection, policy checks, execution, and the following model turn", async () => {
    const artifact = await new LocalDebugHarness().run(request("tool-trace-request", "查看我的任务"));
    const types = artifact.trace.events.map((event) => event.type);
    const selected = types.indexOf("ToolSelected");
    const policy = types.indexOf("PolicyChecked");
    const executed = types.indexOf("ToolExecuted");
    const modelCalls = types.map((type, index) => type === "LLMCall" ? index : -1).filter((index) => index >= 0);
    expect(selected).toBeGreaterThan(modelCalls[0]!);
    expect(policy).toBeGreaterThan(selected);
    expect(executed).toBeGreaterThan(policy);
    expect(modelCalls[1]).toBeGreaterThan(executed);
    expect(artifact.trace.events[executed]?.data).toMatchObject({ toolName: "get_tasks", audited: true });
  });

  it("detects replay drift after a recorded model response is changed", async () => {
    const harness = new LocalDebugHarness();
    const artifact = await harness.run(request("drift-request"));
    const changed = structuredClone(artifact.replayBundle);
    const last = changed.modelResponses.at(-1)!;
    const action = JSON.parse(last.content!) as Record<string, unknown>;
    action["message"] = "回放输出发生变化";
    last.content = JSON.stringify(action);
    await expect(harness.replay(changed)).resolves.toMatchObject({ matched: false });
  });

  it("rejects hidden chain-of-thought fields at the replay schema boundary", async () => {
    const artifact = await new LocalDebugHarness().run(request("cot-request"));
    const unsafe = structuredClone(artifact.replayBundle) as unknown as Record<string, unknown>;
    const responses = unsafe["modelResponses"] as Array<Record<string, unknown>>;
    responses[0]!["reasoningContent"] = "private chain of thought";
    expect(ReplayBundleSchema.safeParse(unsafe).success).toBe(false);
  });

  it("keeps debug endpoints disabled by default and always disabled in production", async () => {
    const harness = new LocalDebugHarness();
    await expect(api(harness, false).runAgent("eval-user", request("disabled-request"))).rejects.toMatchObject({ code: "POLICY_DENIED" });
    await expect(api(harness, true, "production").runAgent("eval-user", request("production-request"))).rejects.toMatchObject({ code: "POLICY_DENIED" });
  });

  it("enforces run ownership and returns a view without raw input or final output", async () => {
    const harness = new LocalDebugHarness();
    const debug = api(harness);
    const artifact = await debug.runAgent("eval-user", request("ownership-request", "private debug prompt"));
    const view = await debug.getRun("eval-user", artifact.response.runId);
    expect(view).toMatchObject({ status: "succeeded", intent: "chat" });
    expect(JSON.stringify(view)).not.toContain("private debug prompt");
    await expect(debug.getRun("another-user", artifact.response.runId)).rejects.toMatchObject({ code: "AUTH_ERROR" });
    await expect(debug.runAgent("another-user", request("cross-user-request"))).rejects.toMatchObject({ code: "AUTH_ERROR" });
  });

  it("routes planning simulation and validation through production deterministic services", async () => {
    const harness = new LocalDebugHarness();
    const debug = api(harness);
    const state = StudentNormalDay(910);
    const planningRequest = {
      state,
      taskIds: [state.activeTasks[0]!.id],
      horizon: state.planningHorizon,
      scope: "day" as const,
      candidateLimit: 2,
      slotGranularityMinutes: 10 as const,
      maximumDailyFocusMinutes: 360,
    };
    const simulated = await debug.handle({
      method: "POST", path: "/planning/simulate", authenticatedUserId: "eval-user", body: planningRequest,
    });
    expect(simulated).toMatchObject({ status: "success" });
    if (!simulated || typeof simulated !== "object" || !("candidates" in simulated)) return;
    const candidate = (simulated as { candidates: Array<{ id: string; blocks: unknown[]; changedExistingBlocks: number; scheduleChangeCost: number }> }).candidates[0]!;
    const validated = await debug.handle({
      method: "POST",
      path: "/planning/validate",
      authenticatedUserId: "eval-user",
      body: {
        request: planningRequest,
        candidate: {
          id: candidate.id,
          blocks: candidate.blocks,
          changedExistingBlocks: candidate.changedExistingBlocks,
          scheduleChangeCost: candidate.scheduleChangeCost,
        },
      },
    });
    expect(validated).toMatchObject({ valid: true, violations: [] });
  });
});

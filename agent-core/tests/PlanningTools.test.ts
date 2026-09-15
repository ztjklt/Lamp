import { describe, expect, it } from "vitest";
import type { ToolExecutionContext } from "../src/agent/tools/AgentTool.js";
import { createPlanningTools } from "../src/tools/planning/PlanningTools.js";
import { fixtureIds, makeStateSnapshot } from "./fixtures/StateFixture.js";

const context: ToolExecutionContext = {
  agent: {
    userId: "user-1", sessionId: "session-1", requestId: "request-1",
    timezone: "Asia/Singapore", locale: "zh-CN", automationLevel: 0,
    authentication: { subject: "user-1", scopes: ["state:read", "planning:read"] },
  },
  runId: fixtureIds.run,
  traceId: fixtureIds.trace,
  state: makeStateSnapshot(),
  activityReader: { listRecentActivity: async () => [] },
  agentRunReader: { listRecentRuns: async () => [] },
};

const planning = {
  taskIds: [fixtureIds.task],
  horizon: { start: "2026-09-08T10:00:00Z", end: "2026-09-08T15:00:00Z" },
  scope: "day" as const,
  candidateLimit: 3,
  slotGranularityMinutes: 30 as const,
  maximumDailyFocusMinutes: 360,
};

describe("planning tools", () => {
  it("registers candidate generation, validation, scoring, conflicts, and simulation as read-only tools", () => {
    const tools = createPlanningTools();
    expect(tools.map((tool) => tool.name).sort()).toEqual([
      "find_schedule_conflicts", "generate_schedule_candidates", "score_schedule_plan",
      "simulate_schedule_change", "validate_schedule_plan",
    ]);
    expect(tools.every((tool) => tool.riskLevel === "READ_ONLY")).toBe(true);
  });

  it("generates a deterministic candidate from state bound by the execution context", async () => {
    const tool = createPlanningTools().find((candidate) => candidate.name === "generate_schedule_candidates");
    const output = await tool!.execute(planning, context) as { status: string; candidates: unknown[] };
    expect(output.status).toBe("success");
    expect(output.candidates.length).toBeGreaterThan(0);
    await expect(tool!.execute({ ...planning, state: {} }, context)).rejects.toThrow();
  });

  it("validates and simulates a generated candidate without mutating the snapshot", async () => {
    const tools = new Map(createPlanningTools().map((tool) => [tool.name, tool]));
    const generated = await tools.get("generate_schedule_candidates")!.execute(planning, context) as {
      candidates: Array<Record<string, unknown>>;
    };
    const candidate = generated.candidates[0];
    expect(candidate).toBeDefined();
    const before = structuredClone(context.state);
    const validation = await tools.get("validate_schedule_plan")!.execute({ candidate, planning }, context) as { valid: boolean };
    const simulation = await tools.get("simulate_schedule_change")!.execute({ candidate, planning }, context) as {
      conflicts: unknown[]; resultingFocusMinutes: number;
    };
    expect(validation.valid).toBe(true);
    expect(simulation.conflicts).toEqual([]);
    expect(simulation.resultingFocusMinutes).toBe(120);
    expect(context.state).toEqual(before);
  });
});

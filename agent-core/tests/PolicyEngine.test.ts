import { describe, expect, it } from "vitest";
import { PermissionPolicy, PolicyEngine, ToolRiskPolicy } from "../src/agent/policies/PolicyEngine.js";
import { defineTool, type ToolExecutionContext, type ToolRiskLevel } from "../src/agent/tools/AgentTool.js";
import { InMemoryHistoryRepository } from "../src/infrastructure/repositories/InMemoryHistoryRepository.js";
import { makeStateSnapshot, fixtureIds } from "./fixtures/StateFixture.js";
import { z } from "zod";

function context(scopes: string[], automationLevel: 0 | 1 | 2): ToolExecutionContext {
  const history = new InMemoryHistoryRepository();
  return {
    agent: {
      userId: "user-1",
      sessionId: "session-1",
      requestId: "request-1",
      timezone: "Asia/Singapore",
      locale: "zh-CN",
      automationLevel,
      authentication: { subject: "user-1", scopes },
    },
    runId: fixtureIds.run,
    traceId: fixtureIds.trace,
    state: makeStateSnapshot(),
    activityReader: history,
    agentRunReader: history,
  };
}

function tool(riskLevel: ToolRiskLevel) {
  return defineTool({
    name: "test_tool",
    version: 1,
    description: "Policy test tool",
    inputSchema: z.object({}).strict(),
    outputSchema: z.object({ ok: z.boolean() }).strict(),
    riskLevel,
    requiredScopes: ["state:read"],
    execute: async () => ({ ok: true }),
  });
}

describe("PolicyEngine", () => {
  const policies = new PolicyEngine([new PermissionPolicy(), new ToolRiskPolicy()]);

  it("allows an authorized read-only tool", async () => {
    await expect(policies.evaluate({
      tool: tool("READ_ONLY"), input: {}, context: context(["state:read"], 0),
    })).resolves.toMatchObject({ decision: "allow" });
  });

  it("denies a tool when its required scope is missing", async () => {
    await expect(policies.evaluate({
      tool: tool("READ_ONLY"), input: {}, context: context([], 2),
    })).resolves.toEqual({
      decision: "deny",
      policyId: "permission_policy",
      reasonCode: "MISSING_TOOL_SCOPE",
    });
  });

  it.each([
    ["LOW_MUTATION", 0, "ask_user"],
    ["LOW_MUTATION", 1, "allow"],
    ["MEDIUM_MUTATION", 2, "ask_user"],
    ["HIGH_MUTATION", 2, "ask_user"],
    ["IRREVERSIBLE", 2, "deny"],
  ] as const)("maps %s at automation level %i to %s", async (risk, level, expected) => {
    const decision = await policies.evaluate({
      tool: tool(risk), input: {}, context: context(["state:read"], level),
    });
    expect(decision.decision).toBe(expected);
  });
});

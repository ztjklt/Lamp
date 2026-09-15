import { describe, expect, it } from "vitest";
import { AgentRun } from "../src/agent/orchestrator/AgentRun.js";
import { PermissionPolicy, PolicyEngine, ToolRiskPolicy } from "../src/agent/policies/PolicyEngine.js";
import { defineTool, type ToolExecutionContext } from "../src/agent/tools/AgentTool.js";
import { ToolExecutor } from "../src/agent/tools/ToolExecutor.js";
import { ToolRegistry } from "../src/agent/tools/ToolRegistry.js";
import { ToolValidator } from "../src/agent/tools/ToolValidator.js";
import { FixedClock } from "../src/infrastructure/clock/FixedClock.js";
import { LampError } from "../src/errors/LampError.js";
import { InMemoryAuditLogRepository } from "../src/infrastructure/repositories/InMemoryAuditLogRepository.js";
import { InMemoryHistoryRepository } from "../src/infrastructure/repositories/InMemoryHistoryRepository.js";
import { AuditLog } from "../src/observability/AuditLog.js";
import { nullLogger } from "../src/observability/Logger.js";
import { createReadTools } from "../src/tools/read/ReadTools.js";
import { createMutationTools } from "../src/tools/mutation/MutationTools.js";
import { fixtureIds, makeStateSnapshot } from "./fixtures/StateFixture.js";
import { z } from "zod";

function harness(scopes = ["state:read", "activity:read", "agent_runs:read"]) {
  const clock = new FixedClock("2026-09-08T08:00:00Z");
  const registry = new ToolRegistry();
  for (const tool of createReadTools()) registry.register(tool);
  const audits = new InMemoryAuditLogRepository();
  const auditLog = new AuditLog(audits, clock, { next: () => fixtureIds.audit });
  const executor = new ToolExecutor(
    registry,
    new ToolValidator(),
    new PolicyEngine([new PermissionPolicy(), new ToolRiskPolicy()]),
    auditLog,
    clock,
    nullLogger,
  );
  const history = new InMemoryHistoryRepository(
    {
      "user-1": [{
        id: "activity-1",
        occurredAt: "2026-09-08T07:00:00Z",
        type: "TaskCompleted",
        summary: "完成英语复习",
        reasonCodes: ["TASK_PRIORITY"],
      }],
    },
    {
      "user-1": [{
        runId: "00000000-0000-4000-8000-000000000120",
        startedAt: "2026-09-08T06:00:00Z",
        endedAt: "2026-09-08T06:00:01Z",
        status: "succeeded",
        intent: "query_schedule",
      }],
    },
  );
  const run = AgentRun.start({
    userId: "user-1",
    sessionId: "session-1",
    requestId: "request-1",
    initialInput: "查看今天安排",
    traceId: fixtureIds.trace,
  }, { clock, ids: { next: () => fixtureIds.run } });
  const context: ToolExecutionContext = {
    agent: {
      userId: "user-1",
      sessionId: "session-1",
      requestId: "request-1",
      timezone: "Asia/Singapore",
      locale: "zh-CN",
      automationLevel: 0,
      authentication: { subject: "user-1", scopes },
    },
    runId: fixtureIds.run,
    traceId: fixtureIds.trace,
    state: makeStateSnapshot(),
    activityReader: history,
    agentRunReader: history,
    run,
  };
  return { registry, executor, audits, context, run };
}

function call(name: string, argumentsValue: Record<string, unknown> = {}) {
  return { id: fixtureIds.call, name, version: 1, arguments: argumentsValue };
}

describe("Tool infrastructure", () => {
  it("registers the complete Phase 3 read-only tool set", () => {
    const { registry } = harness();
    expect(registry.list().map((tool) => tool.name)).toEqual([
      "get_calendar_events",
      "get_current_time",
      "get_free_slots",
      "get_goals",
      "get_recent_activity",
      "get_recent_agent_runs",
      "get_schedule",
      "get_task",
      "get_tasks",
      "get_user_preferences",
      "get_user_profile",
    ]);
    expect(registry.list().every((tool) => tool.riskLevel === "READ_ONLY")).toBe(true);
  });

  it("rejects duplicate tool registration", () => {
    const { registry } = harness();
    const duplicate = createReadTools().find((tool) => tool.name === "get_tasks");
    expect(duplicate).toBeDefined();
    expect(() => registry.register(duplicate!)).toThrowError(/already registered/);
  });

  it("executes an authorized tool, validates output, audits it, and records the run step", async () => {
    const { executor, audits, context, run } = harness();
    const result = await executor.execute(call("get_task", { taskId: fixtureIds.task }), context);

    expect(result.status).toBe("succeeded");
    expect(result.output).toMatchObject({ task: { id: fixtureIds.task, title: "复习高数" } });
    const records = await audits.listByRun(fixtureIds.run);
    expect(records).toHaveLength(1);
    expect(records[0]).toMatchObject({
      toolName: "get_task",
      status: "succeeded",
      policyDecision: { decision: "allow" },
    });
    expect(JSON.stringify(records[0])).not.toContain(fixtureIds.task);
    expect(run.snapshot().toolCalls).toHaveLength(1);
    expect(run.snapshot().policyDecisions).toHaveLength(2);
  });

  it("denies execution when the authenticated context lacks a tool scope", async () => {
    const { executor, audits, context } = harness([]);
    const result = await executor.execute(call("get_tasks"), context);

    expect(result).toMatchObject({
      status: "denied",
      policyDecision: { reasonCode: "MISSING_TOOL_SCOPE" },
    });
    expect((await audits.listByRun(fixtureIds.run))[0]).toMatchObject({ status: "denied" });
  });

  it("rejects arbitrary unregistered tool names without execution", async () => {
    const { executor, audits, context } = harness();
    const result = await executor.execute(call("delete_task"), context);

    expect(result).toMatchObject({ status: "failed", error: { code: "TOOL_ERROR" } });
    expect((await audits.listByRun(fixtureIds.run))[0]).toMatchObject({
      toolName: "delete_task",
      riskLevel: "IRREVERSIBLE",
      status: "failed",
    });
  });

  it("exposes the complete mutation set without a hard-delete tool", () => {
    const tools = createMutationTools();
    expect(tools.map((tool) => tool.name).sort()).toEqual([
      "archive_task", "complete_task", "create_schedule_block", "create_task", "defer_task",
      "lock_schedule_block", "move_schedule_block", "move_task", "remove_schedule_block",
      "resize_schedule_block", "split_task", "unlock_schedule_block", "update_task",
    ]);
    expect(tools.every((tool) => tool.riskLevel === "MEDIUM_MUTATION")).toBe(true);
    expect(tools.some((tool) => tool.name === "delete_task")).toBe(false);
  });

  it("turns a valid task mutation into confirmation_required without changing snapshot state", async () => {
    const { registry, executor, context } = harness(["task:write"]);
    for (const tool of createMutationTools()) registry.register(tool);
    const before = structuredClone(context.state);

    const result = await executor.execute(call("update_task", {
      taskId: fixtureIds.task, expectedVersion: 1, changes: { title: "更新后的标题" },
    }), context);

    expect(result).toMatchObject({ status: "confirmation_required", policyDecision: { reasonCode: "MUTATION_REQUIRES_CONFIRMATION" } });
    expect(context.state).toEqual(before);
  });

  it("rejects protected schedule records before presenting a confirmation", async () => {
    const { registry, executor, context } = harness(["schedule:write"]);
    for (const tool of createMutationTools()) registry.register(tool);

    const result = await executor.execute(call("remove_schedule_block", {
      blockId: fixtureIds.block, expectedVersion: 8,
    }), context);

    expect(result).toMatchObject({ status: "failed", error: { code: "POLICY_DENIED" } });
  });

  it("requires confirmation before a registered medium-risk tool can execute", async () => {
    const { registry, executor, audits, context } = harness();
    let executed = false;
    registry.register(defineTool({
      name: "preview_mutation_boundary",
      version: 1,
      description: "Test-only medium-risk boundary",
      inputSchema: z.object({}).strict(),
      outputSchema: z.object({ ok: z.boolean() }).strict(),
      riskLevel: "MEDIUM_MUTATION",
      requiredScopes: ["state:read"],
      execute: async () => {
        executed = true;
        return { ok: true };
      },
    }));

    const result = await executor.execute(call("preview_mutation_boundary"), context);

    expect(result.status).toBe("confirmation_required");
    expect(executed).toBe(false);
    expect((await audits.listByRun(fixtureIds.run))[0]).toMatchObject({
      status: "confirmation_required",
    });
  });

  it("checks mutation semantics before asking the user to confirm", async () => {
    const { registry, executor, audits, context } = harness();
    let executed = false;
    registry.register(defineTool({
      name: "protected_mutation_fixture",
      version: 1,
      description: "Test-only protected mutation boundary",
      inputSchema: z.object({}).strict(),
      outputSchema: z.object({ ok: z.boolean() }).strict(),
      riskLevel: "MEDIUM_MUTATION",
      requiredScopes: ["state:read"],
      checkPreconditions: async () => {
        throw new LampError({ code: "POLICY_DENIED", message: "protected record", safeMessage: "该记录不可修改。", statusCode: 403 });
      },
      execute: async () => {
        executed = true;
        return { ok: true };
      },
    }));

    const result = await executor.execute(call("protected_mutation_fixture"), context);

    expect(result).toMatchObject({ status: "failed", error: { code: "POLICY_DENIED" } });
    expect(executed).toBe(false);
    expect((await audits.listByRun(fixtureIds.run))[0]).toMatchObject({ status: "failed", errorCode: "POLICY_DENIED" });
  });

  it("rejects and audits output that violates the registered schema", async () => {
    const { registry, executor, audits, context } = harness();
    registry.register(defineTool({
      name: "invalid_output_fixture",
      version: 1,
      description: "Test-only invalid output",
      inputSchema: z.object({}).strict(),
      outputSchema: z.object({ ok: z.boolean() }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read"],
      execute: async () => ({ ok: "invalid" } as unknown as { ok: boolean }),
    }));

    const result = await executor.execute(call("invalid_output_fixture"), context);

    expect(result).toMatchObject({ status: "failed", error: { code: "TOOL_ERROR" } });
    expect((await audits.listByRun(fixtureIds.run))[0]).toMatchObject({
      status: "failed",
      errorCode: "TOOL_ERROR",
    });
  });

  it("fails and audits a range that exceeds the immutable snapshot", async () => {
    const { executor, audits, context } = harness();
    const result = await executor.execute(call("get_schedule", {
      start: "2026-09-08T08:00:00Z",
      end: "2026-09-10T00:00:00Z",
    }), context);

    expect(result).toMatchObject({ status: "failed", error: { code: "VALIDATION_ERROR" } });
    expect((await audits.listByRun(fixtureIds.run))[0]).toMatchObject({
      status: "failed",
      errorCode: "VALIDATION_ERROR",
    });
  });

  it("finds free slots by merging schedule, calendar, and user-blocked intervals", async () => {
    const { executor, context } = harness();
    const result = await executor.execute(call("get_free_slots", {
      start: "2026-09-08T08:00:00Z",
      end: "2026-09-08T20:00:00Z",
      minimumDurationMinutes: 30,
    }), context);

    expect(result.output?.["slots"]).toEqual([
      { start: "2026-09-08T08:00:00Z", end: "2026-09-08T09:00:00Z", durationMinutes: 60 },
      { start: "2026-09-08T10:00:00Z", end: "2026-09-08T15:00:00Z", durationMinutes: 300 },
      { start: "2026-09-08T16:00:00Z", end: "2026-09-08T18:00:00Z", durationMinutes: 120 },
      { start: "2026-09-08T19:00:00Z", end: "2026-09-08T20:00:00Z", durationMinutes: 60 },
    ]);
  });

  it.each([
    ["get_current_time", {}, "now"],
    ["get_user_profile", {}, "user"],
    ["get_user_preferences", {}, "preferences"],
    ["get_tasks", {}, "tasks"],
    ["get_goals", {}, "goals"],
    ["get_schedule", { start: "2026-09-08T08:00:00Z", end: "2026-09-08T20:00:00Z" }, "blocks"],
    ["get_calendar_events", { start: "2026-09-08T08:00:00Z", end: "2026-09-08T20:00:00Z" }, "events"],
    ["get_recent_activity", {}, "activity"],
    ["get_recent_agent_runs", {}, "runs"],
  ] as const)("executes %s through the common pipeline", async (name, input, outputKey) => {
    const { executor, context } = harness();
    const result = await executor.execute(call(name, input), context);
    expect(result.status).toBe("succeeded");
    expect(result.output).toHaveProperty(outputKey);
  });
});

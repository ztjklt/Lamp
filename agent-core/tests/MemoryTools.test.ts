import { describe, expect, it } from "vitest";
import { MemoryEngine } from "../src/agent/memory/MemoryEngine.js";
import { MemoryPolicy } from "../src/agent/memory/MemoryPolicy.js";
import { PermissionPolicy, PolicyEngine, ToolRiskPolicy } from "../src/agent/policies/PolicyEngine.js";
import type { ToolExecutionContext } from "../src/agent/tools/AgentTool.js";
import { ToolExecutor } from "../src/agent/tools/ToolExecutor.js";
import { ToolRegistry } from "../src/agent/tools/ToolRegistry.js";
import { ToolValidator } from "../src/agent/tools/ToolValidator.js";
import { FixedClock } from "../src/infrastructure/clock/FixedClock.js";
import { InMemoryAuditLogRepository } from "../src/infrastructure/repositories/InMemoryAuditLogRepository.js";
import { InMemoryHistoryRepository } from "../src/infrastructure/repositories/InMemoryHistoryRepository.js";
import {
  InMemoryMemoryCandidateRepository,
  InMemoryPreferenceMemoryRepository,
} from "../src/infrastructure/repositories/InMemoryMemoryRepositories.js";
import { AuditLog } from "../src/observability/AuditLog.js";
import { nullLogger } from "../src/observability/Logger.js";
import { createMemoryTools } from "../src/tools/memory/MemoryTools.js";
import { fixtureIds, makeStateSnapshot } from "./fixtures/StateFixture.js";

const candidateId = "00000000-0000-4000-8000-000000000501";
const memoryId = "00000000-0000-4000-8000-000000000502";

function explicitInput() {
  return {
    preference: { key: "preferred_study_period" as const, value: "evening" as const },
    confidence: 0.95,
    source: "user_explicit" as const,
    evidence: [{
      sourceType: "user_message" as const,
      referenceId: "message-1",
      observedAt: "2026-09-08T08:00:00Z",
      summary: "用户明确偏好晚间学习",
    }],
    reasonCodes: ["USER_STATED_PREFERENCE"],
  };
}

function harness(automationLevel: 0 | 1 | 2) {
  const clock = new FixedClock("2026-09-08T08:00:00Z");
  const candidates = new InMemoryMemoryCandidateRepository();
  const preferences = new InMemoryPreferenceMemoryRepository();
  const generatedIds = [candidateId, memoryId];
  const memory = new MemoryEngine(candidates, preferences, new MemoryPolicy(), clock, {
    next: () => generatedIds.shift()!,
  });
  const registry = new ToolRegistry();
  for (const tool of createMemoryTools(memory)) registry.register(tool);
  const executor = new ToolExecutor(
    registry,
    new ToolValidator(),
    new PolicyEngine([new PermissionPolicy(), new ToolRiskPolicy()]),
    new AuditLog(new InMemoryAuditLogRepository(), clock, { next: () => fixtureIds.audit }),
    clock,
    nullLogger,
  );
  const history = new InMemoryHistoryRepository();
  const context: ToolExecutionContext = {
    agent: {
      userId: "user-1", sessionId: "session-1", requestId: "request-1",
      timezone: "Asia/Singapore", locale: "zh-CN", automationLevel,
      authentication: { subject: "user-1", scopes: ["memory:read", "memory:propose", "memory:write"] },
    },
    runId: fixtureIds.run,
    traceId: fixtureIds.trace,
    state: makeStateSnapshot(),
    activityReader: history,
    agentRunReader: history,
  };
  return { registry, executor, context, memory, candidates, preferences };
}

function call(name: string, argumentsValue: Record<string, unknown>) {
  return { id: fixtureIds.call, name, version: 1, arguments: argumentsValue };
}

describe("memory tools", () => {
  it("registers search, candidate, and preference-update tools with explicit risk levels", () => {
    const { registry } = harness(0);
    expect(registry.list().map((tool) => [tool.name, tool.riskLevel])).toEqual([
      ["search_memory", "READ_ONLY"],
      ["update_preference", "MEDIUM_MUTATION"],
      ["write_memory_candidate", "LOW_MUTATION"],
    ]);
  });

  it("requires confirmation before a level-zero agent may even write a candidate", async () => {
    const { executor, context, candidates } = harness(0);
    await expect(executor.execute(call("write_memory_candidate", explicitInput()), context))
      .resolves.toMatchObject({ status: "confirmation_required" });
    await expect(candidates.getById(candidateId)).resolves.toBeNull();
  });

  it("allows candidate creation at level one but does not create permanent memory", async () => {
    const { executor, context, preferences } = harness(1);
    await expect(executor.execute(call("write_memory_candidate", explicitInput()), context))
      .resolves.toMatchObject({ status: "succeeded", output: { candidate: { status: "eligible" } } });
    await expect(preferences.listCurrent("user-1")).resolves.toEqual([]);
  });

  it("keeps permanent preference updates behind the medium-risk confirmation gate", async () => {
    const { executor, context, memory, preferences } = harness(2);
    const proposal = await memory.propose("user-1", explicitInput());
    await expect(executor.execute(call("update_preference", { candidateId: proposal.candidate.candidateId }), context))
      .resolves.toMatchObject({ status: "confirmation_required" });
    await expect(preferences.listCurrent("user-1")).resolves.toEqual([]);
  });

  it("searches only approved current memory through the read-only tool", async () => {
    const { executor, context, memory } = harness(0);
    const proposal = await memory.propose("user-1", explicitInput());
    await memory.approve({ userId: "user-1", candidateId: proposal.candidate.candidateId, approvedBy: "policy" });
    await expect(executor.execute(call("search_memory", {
      keys: ["preferred_study_period"],
      keywords: ["evening"],
      limit: 5,
    }), context)).resolves.toMatchObject({
      status: "succeeded",
      output: { memories: [{ preference: { key: "preferred_study_period", value: "evening" }, version: 1 }] },
    });
  });
});

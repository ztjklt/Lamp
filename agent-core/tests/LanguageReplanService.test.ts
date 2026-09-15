import { describe, expect, it } from "vitest";
import type { LLMProvider } from "../src/llm/LLMProvider.js";
import type { LLMRequest } from "../src/llm/LLMRequest.js";
import type { LLMResponse } from "../src/llm/LLMResponse.js";
import { InvalidLanguageDecisionError, LanguageReplanService } from "../src/api/LanguageReplanService.js";

const ids = {
  request: "40000000-0000-4000-8000-000000000001",
  mathTask: "40000000-0000-4000-8000-000000000002",
  englishTask: "40000000-0000-4000-8000-000000000003",
  mathBlock: "40000000-0000-4000-8000-000000000004",
  englishBlock: "40000000-0000-4000-8000-000000000005",
  fixedBlock: "40000000-0000-4000-8000-000000000006",
};

function request() {
  return {
    schemaVersion: 1 as const,
    requestId: ids.request,
    sourceFingerprint: "d".repeat(64),
    requestedAt: "2026-09-08T11:45:00Z",
    timezone: "Asia/Singapore",
    locale: "zh-CN",
    input: "今天有点累，高数少学一点。",
    planningHorizon: { start: "2026-09-08T11:45:00Z", end: "2026-09-08T16:00:00Z" },
    tasks: [
      {
        id: ids.mathTask, goalId: null, title: "复习高数", detail: "第二章", importance: 5,
        deadline: "2026-09-08T15:00:00Z", estimatedMinutes: 60, remainingMinutes: 60,
        isPaused: false, isSplittable: true, minimumSessionMinutes: 15, maximumSessionMinutes: 90,
        preferredPeriods: ["evening" as const], dependencyIds: [], availableWindows: [],
      },
      {
        id: ids.englishTask, goalId: null, title: "复习英语", detail: "阅读", importance: 3,
        deadline: null, estimatedMinutes: 50, remainingMinutes: 50,
        isPaused: false, isSplittable: true, minimumSessionMinutes: 15, maximumSessionMinutes: 90,
        preferredPeriods: ["evening" as const], dependencyIds: [], availableWindows: [],
      },
    ],
    schedule: [
      {
        id: ids.mathBlock, taskId: ids.mathTask, title: "复习高数",
        startsAt: "2026-09-08T12:00:00Z", endsAt: "2026-09-08T13:00:00Z",
        kind: "focus" as const, state: "planned" as const, locked: false, provenance: "Lamp",
      },
      {
        id: ids.englishBlock, taskId: ids.englishTask, title: "复习英语",
        startsAt: "2026-09-08T13:10:00Z", endsAt: "2026-09-08T14:00:00Z",
        kind: "focus" as const, state: "planned" as const, locked: false, provenance: "Lamp",
      },
      {
        id: ids.fixedBlock, taskId: null, title: "固定课程",
        startsAt: "2026-09-08T14:15:00Z", endsAt: "2026-09-08T15:00:00Z",
        kind: "fixed" as const, state: "planned" as const, locked: true, provenance: "Calendar",
      },
    ],
    preferences: {
      preferredFocusMinutes: 50, preferredBreakMinutes: 10,
      morningStudyPreference: 0.2, eveningStudyPreference: 0.8,
    },
  };
}

function response(content: unknown): LLMResponse {
  return {
    id: "language-response-1",
    provider: "mock-deepseek",
    model: "mock-flash",
    content: JSON.stringify(content),
    toolCalls: [],
    finishReason: "stop",
    usage: { inputTokens: 20, outputTokens: 10, totalTokens: 30, cacheHitTokens: 0, cacheMissTokens: 20 },
    latencyMs: 4,
  };
}

function decision(taskId = ids.mathTask) {
  return {
    intent: "replan_schedule",
    action: "reduce_task_workload",
    taskId,
    targetMinutes: 30,
    scope: "day",
    temporaryState: "tired",
    reasonCodes: ["USER_REPORTED_FATIGUE", "USER_REQUESTED_WORKLOAD_REDUCTION"],
    confidence: 0.96,
  };
}

describe("LanguageReplanService", () => {
  it("combines a grounded model decision with deterministic local plan changes", async () => {
    const requests: LLMRequest[] = [];
    const provider: LLMProvider = {
      name: "mock-deepseek",
      generate: async (modelRequest) => {
        requests.push(structuredClone(modelRequest));
        return response(decision());
      },
    };
    const input = request();
    const original = structuredClone(input);
    const result = await new LanguageReplanService(provider, { model: "mock-flash" }).createProposal(input);

    expect(input).toEqual(original);
    expect(requests).toHaveLength(1);
    expect(JSON.stringify(requests[0]!.messages)).toContain("复习高数");
    expect(result).toMatchObject({ status: "proposal", commitRequired: true });
    if (result.status !== "proposal") throw new Error("expected proposal");
    expect(result.trace).toMatchObject({
      model: { provider: "mock-deepseek", model: "mock-flash" },
      intent: "replan_schedule",
      decision: { taskId: ids.mathTask, targetMinutes: 30 },
    });
    expect(result.proposal.changes).toEqual([
      expect.objectContaining({ type: "RESIZE", taskId: ids.mathTask, previousBlockId: ids.mathBlock }),
    ]);
    expect(JSON.stringify(result.proposal)).not.toContain(ids.englishBlock);
    expect(JSON.stringify(result.proposal)).not.toContain(ids.fixedBlock);
    const minutes = result.proposal.blocks.reduce((sum, block) =>
      sum + (Date.parse(block.endsAt) - Date.parse(block.startsAt)) / 60_000, 0);
    expect(minutes).toBe(30);
  });

  it("rejects an ungrounded task id before planning", async () => {
    const provider: LLMProvider = { name: "mock", generate: async () => response(decision("40000000-0000-4000-8000-999999999999")) };
    await expect(new LanguageReplanService(provider, { model: "mock" }).createProposal(request()))
      .rejects.toBeInstanceOf(InvalidLanguageDecisionError);
  });

  it("does not execute the model or planner twice for the same request", async () => {
    let calls = 0;
    const provider: LLMProvider = { name: "mock", generate: async () => { calls += 1; return response(decision()); } };
    const service = new LanguageReplanService(provider, { model: "mock" });
    const first = await service.createProposal(request(), "user-1");
    const second = await service.createProposal(request(), "user-1");
    expect(second).toEqual(first);
    expect(calls).toBe(1);
  });
});

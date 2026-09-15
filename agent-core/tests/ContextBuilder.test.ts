import { describe, expect, it } from "vitest";
import { ContextBudget } from "../src/agent/context/ContextBudget.js";
import { ContextBuilder } from "../src/agent/context/ContextBuilder.js";
import type { LLMMessage } from "../src/llm/LLMRequest.js";
import { makeStateSnapshot } from "./fixtures/StateFixture.js";

describe("ContextBuilder", () => {
  it("keeps the newest tool-call group intact while enforcing a working-context budget", () => {
    const builder = new ContextBuilder(new ContextBudget(4_000));
    const base: LLMMessage[] = [
      { role: "system", content: "s" },
      { role: "system", content: "p" },
      { role: "system", content: "c" },
      { role: "user", content: "u" },
    ];
    const messages: LLMMessage[] = [
      ...base,
      { role: "assistant", content: "old" },
      { role: "system", content: "x".repeat(3_000) },
      { role: "assistant", content: null, toolCalls: [{ id: "call-1", name: "get_tasks", arguments: {} }] },
      { role: "tool", name: "get_tasks", toolCallId: "call-1", content: "y".repeat(3_000) },
    ];
    const compacted = builder.compactMessages(messages);
    expect(JSON.stringify(compacted).length).toBeLessThanOrEqual(4_000);
    expect(compacted).toContainEqual(expect.objectContaining({ role: "assistant", toolCalls: expect.any(Array) }));
    expect(compacted).toContainEqual(expect.objectContaining({ role: "tool", toolCallId: "call-1" }));
    expect(compacted).toContainEqual(expect.objectContaining({ content: "EARLIER_WORKING_CONTEXT_OMITTED_BY_BUDGET" }));
  });

  it("includes only summarized approved and run-scoped memory in current context", () => {
    const builder = new ContextBuilder();
    const messages = builder.build(
      "安排复习",
      {
        userId: "user-1", sessionId: "session-1", requestId: "request-1",
        timezone: "Asia/Singapore", locale: "zh-CN", automationLevel: 0,
        authentication: { subject: "user-1", scopes: [] },
      },
      makeStateSnapshot(),
      [{
        memoryId: "00000000-0000-4000-8000-000000000401",
        userId: "user-1",
        type: "preference",
        preference: { key: "preferred_study_period", value: "evening" },
        version: 2,
        supersedesMemoryId: "00000000-0000-4000-8000-000000000400",
        createdAt: "2026-09-08T08:00:00Z", updatedAt: "2026-09-08T08:00:00Z",
        confidence: 0.95, source: "user_explicit", explicitOrInferred: "explicit",
        evidence: [{ sourceType: "user_message", referenceId: "secret-reference", observedAt: "2026-09-08T08:00:00Z", summary: "private raw evidence" }],
        sourceCandidateId: "00000000-0000-4000-8000-000000000402",
      }],
      [{
        workingMemoryId: "00000000-0000-4000-8000-000000000403",
        userId: "user-1", sessionId: "session-1", runId: "00000000-0000-4000-8000-000000000404",
        key: "current_goal", value: { goal: "math" }, createdAt: "2026-09-08T08:00:00Z",
        updatedAt: "2026-09-08T08:00:00Z", expiresAt: "2026-09-08T10:00:00Z",
      }],
    );
    const context = messages[2]?.content ?? "";
    expect(context).toContain("preferred_study_period");
    expect(context).toContain("current_goal");
    expect(context).not.toContain("private raw evidence");
    expect(context).not.toContain("secret-reference");
  });
});

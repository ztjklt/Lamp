import { describe, expect, it } from "vitest";
import type { LLMProvider } from "../src/llm/LLMProvider.js";
import { LLMGateway } from "../src/llm/LLMGateway.js";
import type { LLMRequest } from "../src/llm/LLMRequest.js";
import { StructuredLogger, type LogRecord } from "../src/observability/Logger.js";

const context = {
  traceId: "00000000-0000-4000-8000-000000000001",
  runId: "00000000-0000-4000-8000-000000000002",
};

describe("LLMGateway", () => {
  it("validates and logs model metadata but not model content or reasoning", async () => {
    const records: LogRecord[] = [];
    const logger = new StructuredLogger("debug", () => "2026-09-08T00:00:00.000Z", (record) => {
      records.push(record as LogRecord);
    });
    const provider: LLMProvider = {
      name: "mock",
      generate: async () => ({
        id: "response-1",
        provider: "mock",
        model: "mock-model",
        content: "private user response",
        reasoningContent: "private reasoning",
        toolCalls: [],
        finishReason: "stop",
        usage: { inputTokens: 10, outputTokens: 5, totalTokens: 15, cacheHitTokens: 0, cacheMissTokens: 10 },
        latencyMs: 12,
      }),
    };
    const gateway = new LLMGateway(provider, logger);
    const request: LLMRequest = {
      messages: [{ role: "user", content: "private user input" }],
      responseFormat: "text",
      thinking: { enabled: false },
    };

    const response = await gateway.generate(request, context);

    expect(response.content).toBe("private user response");
    expect(records.map((record) => record.event)).toEqual(["model_call_started", "model_call_succeeded"]);
    const serializedLogs = JSON.stringify(records);
    expect(serializedLogs).not.toContain("private user input");
    expect(serializedLogs).not.toContain("private user response");
    expect(serializedLogs).not.toContain("private reasoning");
  });

  it("rejects required tool choice without tool definitions before provider invocation", async () => {
    let called = false;
    const provider: LLMProvider = {
      name: "mock",
      generate: async () => {
        called = true;
        throw new Error("must not be called");
      },
    };
    const gateway = new LLMGateway(provider, {
      debug: () => undefined,
      info: () => undefined,
      warn: () => undefined,
      error: () => undefined,
    });
    const invalid = {
      messages: [{ role: "user", content: "hello" }],
      toolChoice: "required",
      responseFormat: "text",
      thinking: { enabled: false },
    } as LLMRequest;

    await expect(gateway.generate(invalid, context)).rejects.toMatchObject({ code: "VALIDATION_ERROR" });
    expect(called).toBe(false);
  });
});

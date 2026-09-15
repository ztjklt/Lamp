import { describe, expect, it } from "vitest";
import { DeepSeekProvider } from "../src/llm/DeepSeekProvider.js";
import { LampError } from "../src/errors/LampError.js";
import type { LLMRequest } from "../src/llm/LLMRequest.js";

const request: LLMRequest = {
  messages: [{ role: "user", content: "安排明天下午复习高数" }],
  tools: [{
    name: "create_task",
    description: "Create a task proposal",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["title"],
      properties: { title: { type: "string" } },
    },
  }],
  toolChoice: "required",
  responseFormat: "text",
  thinking: { enabled: false },
};

describe("DeepSeekProvider", () => {
  it("normalizes a tool response without exposing provider details to callers", async () => {
    let sentBody: Record<string, unknown> | undefined;
    const provider = new DeepSeekProvider({
      apiKey: "test-key",
      defaultModel: "deepseek-v4-flash",
      monotonicNow: (() => {
        const values = [100, 125];
        return () => values.shift() ?? 125;
      })(),
      fetchImplementation: async (_input, init) => {
        sentBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
        return Response.json({
          id: "completion-1",
          model: "deepseek-v4-flash",
          choices: [{
            finish_reason: "tool_calls",
            message: {
              content: null,
              tool_calls: [{
                id: "call-1",
                type: "function",
                function: { name: "create_task", arguments: "{\"title\":\"复习高数\"}" },
              }],
            },
          }],
          usage: {
            prompt_tokens: 100,
            completion_tokens: 20,
            total_tokens: 120,
            prompt_cache_hit_tokens: 30,
            prompt_cache_miss_tokens: 70,
          },
        });
      },
    });

    const response = await provider.generate(request);

    expect(sentBody).toMatchObject({
      model: "deepseek-v4-flash",
      tool_choice: "required",
      thinking: { type: "disabled" },
    });
    expect(response.toolCalls).toEqual([{ id: "call-1", name: "create_task", arguments: { title: "复习高数" } }]);
    expect(response.usage.cacheHitTokens).toBe(30);
    expect(response.latencyMs).toBe(25);
  });

  it("maps thinking effort to the official top-level request field", async () => {
    let sentBody: Record<string, unknown> | undefined;
    const provider = new DeepSeekProvider({
      apiKey: "test-key",
      defaultModel: "deepseek-v4-pro",
      fetchImplementation: async (_input, init) => {
        sentBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
        return Response.json({
          id: "completion-1",
          model: "deepseek-v4-pro",
          choices: [{ finish_reason: "stop", message: { content: "ok" } }],
          usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
        });
      },
    });

    await provider.generate({
      messages: [{ role: "user", content: "review" }],
      responseFormat: "text",
      thinking: { enabled: true, reasoningEffort: "max" },
    });

    expect(sentBody).toMatchObject({
      thinking: { type: "enabled" },
      reasoning_effort: "max",
    });
    expect((sentBody?.["thinking"] as Record<string, unknown>)["reasoning_effort"]).toBeUndefined();
  });

  it("rejects malformed model tool arguments", async () => {
    const provider = new DeepSeekProvider({
      apiKey: "test-key",
      defaultModel: "deepseek-v4-flash",
      fetchImplementation: async () => Response.json({
        id: "completion-1",
        model: "deepseek-v4-flash",
        choices: [{
          finish_reason: "tool_calls",
          message: {
            content: null,
            tool_calls: [{
              id: "call-1",
              type: "function",
              function: { name: "create_task", arguments: "not-json" },
            }],
          },
        }],
        usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
      }),
    });

    await expect(provider.generate(request)).rejects.toMatchObject({
      code: "MODEL_INVALID_OUTPUT",
    } satisfies Partial<LampError>);
  });

  it("classifies provider rate limits as retryable", async () => {
    const provider = new DeepSeekProvider({
      apiKey: "test-key",
      defaultModel: "deepseek-v4-flash",
      fetchImplementation: async () => new Response(null, { status: 429 }),
    });

    await expect(provider.generate(request)).rejects.toMatchObject({
      code: "RATE_LIMIT",
      retryable: true,
    } satisfies Partial<LampError>);
  });

  it("serializes assistant tool calls for a valid multi-turn tool conversation", async () => {
    let sentBody: Record<string, unknown> | undefined;
    const provider = new DeepSeekProvider({
      apiKey: "test-key",
      defaultModel: "deepseek-v4-flash",
      fetchImplementation: async (_input, init) => {
        sentBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
        return Response.json({
          id: "completion-2",
          model: "deepseek-v4-flash",
          choices: [{ finish_reason: "stop", message: { content: "{}" } }],
          usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
        });
      },
    });
    await provider.generate({
      messages: [
        { role: "user", content: "查看任务" },
        { role: "assistant", content: null, toolCalls: [{ id: "call-1", name: "get_tasks", arguments: {} }] },
        { role: "tool", content: "{\"tasks\":[]}", name: "get_tasks", toolCallId: "call-1" },
      ],
      responseFormat: "json_object",
      thinking: { enabled: false },
    });
    const messages = sentBody?.["messages"] as Array<Record<string, unknown>>;
    expect(messages[1]).toMatchObject({
      role: "assistant",
      tool_calls: [{ id: "call-1", type: "function", function: { name: "get_tasks", arguments: "{}" } }],
    });
    expect(messages[2]).toMatchObject({ role: "tool", tool_call_id: "call-1" });
  });
});

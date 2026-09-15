import { z } from "zod";
import { LampError } from "../errors/LampError.js";
import type { LLMProvider } from "./LLMProvider.js";
import type { LLMRequest } from "./LLMRequest.js";
import type { LLMResponse, LLMToolCall } from "./LLMResponse.js";

const DeepSeekResponseSchema = z.object({
  id: z.string().min(1),
  model: z.string().min(1),
  choices: z.array(z.object({
    finish_reason: z.string().nullable(),
    message: z.object({
      content: z.string().nullable().optional(),
      reasoning_content: z.string().nullable().optional(),
      tool_calls: z.array(z.object({
        id: z.string().min(1),
        type: z.literal("function"),
        function: z.object({
          name: z.string().min(1),
          arguments: z.string(),
        }),
      })).optional(),
    }),
  })).min(1),
  usage: z.object({
    prompt_tokens: z.number().int().nonnegative(),
    completion_tokens: z.number().int().nonnegative(),
    total_tokens: z.number().int().nonnegative(),
    prompt_cache_hit_tokens: z.number().int().nonnegative().optional(),
    prompt_cache_miss_tokens: z.number().int().nonnegative().optional(),
  }),
}).passthrough();

export interface DeepSeekProviderOptions {
  apiKey: string;
  baseUrl?: string;
  defaultModel: string;
  timeoutMs?: number;
  fetchImplementation?: typeof fetch;
  monotonicNow?: () => number;
}

export class DeepSeekProvider implements LLMProvider {
  readonly name = "deepseek";
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly fetchImplementation: typeof fetch;
  private readonly monotonicNow: () => number;

  constructor(private readonly options: DeepSeekProviderOptions) {
    if (options.apiKey.trim().length === 0) {
      throw new LampError({
        code: "VALIDATION_ERROR",
        message: "DeepSeek API key is required",
        safeMessage: "DeepSeek Provider 配置不完整。",
      });
    }
    this.baseUrl = (options.baseUrl ?? "https://api.deepseek.com").replace(/\/$/, "");
    this.timeoutMs = options.timeoutMs ?? 20_000;
    this.fetchImplementation = options.fetchImplementation ?? globalThis.fetch;
    this.monotonicNow = options.monotonicNow ?? performance.now.bind(performance);
  }

  async generate(request: LLMRequest): Promise<LLMResponse> {
    const startedAt = this.monotonicNow();
    let response: Response;
    try {
      response = await this.fetchImplementation(`${this.baseUrl}/chat/completions`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${this.options.apiKey}`,
        },
        body: JSON.stringify(this.toDeepSeekRequest(request)),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (error) {
      if (isAbortError(error)) {
        throw new LampError({
          code: "MODEL_TIMEOUT",
          message: `DeepSeek timed out after ${this.timeoutMs}ms`,
          safeMessage: "模型响应超时，请稍后重试。",
          retryable: true,
          statusCode: 504,
          cause: error,
        });
      }
      throw new LampError({
        code: "LLM_ERROR",
        message: "DeepSeek request failed",
        safeMessage: "暂时无法连接模型服务。",
        retryable: true,
        statusCode: 503,
        cause: error,
      });
    }

    if (!response.ok) throw await this.providerHttpError(response);

    let rawBody: unknown;
    try {
      rawBody = await response.json();
    } catch (error) {
      throw invalidOutput("DeepSeek returned non-JSON output", error);
    }
    const parsed = DeepSeekResponseSchema.safeParse(rawBody);
    if (!parsed.success) {
      throw invalidOutput("DeepSeek response envelope failed validation", parsed.error);
    }

    const choice = parsed.data.choices[0];
    if (!choice) throw invalidOutput("DeepSeek response did not include a choice");
    const toolCalls = (choice.message.tool_calls ?? []).map(parseToolCall);
    const elapsed = Math.max(0, Math.round(this.monotonicNow() - startedAt));
    return {
      id: parsed.data.id,
      provider: this.name,
      model: parsed.data.model,
      content: choice.message.content ?? null,
      ...(choice.message.reasoning_content == null
        ? {}
        : { reasoningContent: choice.message.reasoning_content }),
      toolCalls,
      finishReason: normalizeFinishReason(choice.finish_reason),
      usage: {
        inputTokens: parsed.data.usage.prompt_tokens,
        outputTokens: parsed.data.usage.completion_tokens,
        totalTokens: parsed.data.usage.total_tokens,
        cacheHitTokens: parsed.data.usage.prompt_cache_hit_tokens ?? 0,
        cacheMissTokens: parsed.data.usage.prompt_cache_miss_tokens ?? 0,
      },
      latencyMs: elapsed,
    };
  }

  private toDeepSeekRequest(request: LLMRequest): Record<string, unknown> {
    return {
      model: request.model ?? this.options.defaultModel,
      messages: request.messages.map((message) => ({
        role: message.role,
        content: message.content,
        ...(message.name === undefined ? {} : { name: message.name }),
        ...(message.toolCallId === undefined ? {} : { tool_call_id: message.toolCallId }),
        ...(message.toolCalls === undefined ? {} : {
          tool_calls: message.toolCalls.map((call) => ({
            id: call.id,
            type: "function",
            function: { name: call.name, arguments: JSON.stringify(call.arguments) },
          })),
        }),
        ...(message.reasoningContent === undefined ? {} : { reasoning_content: message.reasoningContent }),
      })),
      thinking: {
        type: request.thinking.enabled ? "enabled" : "disabled",
      },
      ...(request.thinking.reasoningEffort === undefined
        ? {}
        : { reasoning_effort: request.thinking.reasoningEffort }),
      ...(request.tools === undefined ? {} : {
        tools: request.tools.map((tool) => ({
          type: "function",
          function: {
            name: tool.name,
            description: tool.description,
            parameters: tool.inputSchema,
          },
        })),
      }),
      ...(request.toolChoice === undefined ? {} : { tool_choice: request.toolChoice }),
      ...(request.responseFormat === "json_object"
        ? { response_format: { type: "json_object" } }
        : {}),
      ...(request.temperature === undefined ? {} : { temperature: request.temperature }),
      ...(request.maxOutputTokens === undefined ? {} : { max_tokens: request.maxOutputTokens }),
    };
  }

  private async providerHttpError(response: Response): Promise<LampError> {
    const retryable = response.status === 408 || response.status === 429 || response.status >= 500;
    const code = response.status === 429 ? "RATE_LIMIT" : "LLM_ERROR";
    let providerRequestId: string | null = null;
    try {
      providerRequestId = response.headers.get("x-request-id");
    } catch {
      providerRequestId = null;
    }
    return new LampError({
      code,
      message: `DeepSeek returned HTTP ${response.status}`,
      safeMessage: response.status === 429 ? "模型请求过于频繁，请稍后重试。" : "模型服务暂时不可用。",
      retryable,
      statusCode: response.status === 429 ? 429 : 502,
      details: providerRequestId === null ? {} : { providerRequestId },
    });
  }
}

type DeepSeekToolCall = NonNullable<
  z.infer<typeof DeepSeekResponseSchema>["choices"][number]["message"]["tool_calls"]
>[number];

function parseToolCall(raw: DeepSeekToolCall): LLMToolCall {
  let argumentsValue: unknown;
  try {
    argumentsValue = JSON.parse(raw.function.arguments);
  } catch (error) {
    throw invalidOutput(`Invalid JSON arguments for tool ${raw.function.name}`, error);
  }
  if (!argumentsValue || typeof argumentsValue !== "object" || Array.isArray(argumentsValue)) {
    throw invalidOutput(`Tool ${raw.function.name} arguments must be an object`);
  }
  if (!/^[a-z][a-z0-9_]{1,79}$/.test(raw.function.name)) {
    throw invalidOutput("DeepSeek returned an invalid tool name");
  }
  return {
    id: raw.id,
    name: raw.function.name,
    arguments: argumentsValue as Record<string, unknown>,
  };
}

function normalizeFinishReason(value: string | null): LLMResponse["finishReason"] {
  if (value === "stop" || value === "length" || value === "tool_calls" || value === "content_filter") {
    return value;
  }
  return "unknown";
}

function invalidOutput(message: string, cause?: unknown): LampError {
  return new LampError({
    code: "MODEL_INVALID_OUTPUT",
    message,
    safeMessage: "模型返回了无法验证的结果。",
    retryable: true,
    statusCode: 502,
    cause,
  });
}

function isAbortError(error: unknown): boolean {
  return error instanceof DOMException && (error.name === "AbortError" || error.name === "TimeoutError");
}

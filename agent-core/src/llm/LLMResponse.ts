import { z } from "zod";

export const LLMToolCallSchema = z.object({
  id: z.string().min(1),
  name: z.string().regex(/^[a-z][a-z0-9_]{1,79}$/),
  arguments: z.record(z.string(), z.unknown()),
}).strict();

export const LLMUsageSchema = z.object({
  inputTokens: z.number().int().nonnegative(),
  outputTokens: z.number().int().nonnegative(),
  totalTokens: z.number().int().nonnegative(),
  cacheHitTokens: z.number().int().nonnegative(),
  cacheMissTokens: z.number().int().nonnegative(),
}).strict();

export const LLMResponseSchema = z.object({
  id: z.string().min(1),
  provider: z.string().min(1),
  model: z.string().min(1),
  content: z.string().nullable(),
  reasoningContent: z.string().optional(),
  toolCalls: z.array(LLMToolCallSchema),
  finishReason: z.enum(["stop", "length", "tool_calls", "content_filter", "unknown"]),
  usage: LLMUsageSchema,
  latencyMs: z.number().int().nonnegative(),
}).strict();

export type LLMToolCall = z.infer<typeof LLMToolCallSchema>;
export type LLMUsage = z.infer<typeof LLMUsageSchema>;
export type LLMResponse = z.infer<typeof LLMResponseSchema>;

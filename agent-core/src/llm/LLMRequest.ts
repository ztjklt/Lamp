import { z } from "zod";

export const LLMMessageToolCallSchema = z.object({
  id: z.string().min(1),
  name: z.string().regex(/^[a-z][a-z0-9_]{1,79}$/),
  arguments: z.record(z.string(), z.unknown()),
}).strict();

export const LLMMessageSchema = z.object({
  role: z.enum(["system", "user", "assistant", "tool"]),
  content: z.string().nullable(),
  name: z.string().min(1).optional(),
  toolCallId: z.string().min(1).optional(),
  toolCalls: z.array(LLMMessageToolCallSchema).max(20).optional(),
  reasoningContent: z.string().optional(),
}).strict().superRefine((message, context) => {
  if (message.role !== "assistant" && message.toolCalls !== undefined) {
    context.addIssue({ code: "custom", path: ["toolCalls"], message: "toolCalls are only valid on assistant messages" });
  }
  if (message.role !== "tool" && message.toolCallId !== undefined) {
    context.addIssue({ code: "custom", path: ["toolCallId"], message: "toolCallId is only valid on tool messages" });
  }
});

export const LLMToolDefinitionSchema = z.object({
  name: z.string().regex(/^[a-z][a-z0-9_]{1,79}$/),
  description: z.string().min(1).max(2_000),
  inputSchema: z.record(z.string(), z.unknown()),
}).strict();

export const LLMRequestSchema = z.object({
  model: z.string().min(1).optional(),
  messages: z.array(LLMMessageSchema).min(1).max(100),
  tools: z.array(LLMToolDefinitionSchema).max(50).optional(),
  toolChoice: z.enum(["none", "auto", "required"]).optional(),
  responseFormat: z.enum(["text", "json_object"]).default("text"),
  thinking: z.object({
    enabled: z.boolean(),
    reasoningEffort: z.enum(["low", "high", "max"]).optional(),
  }).strict().default({ enabled: false }),
  temperature: z.number().min(0).max(2).optional(),
  maxOutputTokens: z.number().int().positive().max(32_768).optional(),
  metadata: z.record(z.string(), z.string().max(500)).optional(),
}).strict().superRefine((request, context) => {
  if (request.toolChoice === "required" && (!request.tools || request.tools.length === 0)) {
    context.addIssue({
      code: "custom",
      path: ["toolChoice"],
      message: "toolChoice=required requires at least one tool",
    });
  }
});

export type LLMMessage = z.infer<typeof LLMMessageSchema>;
export type LLMMessageToolCall = z.infer<typeof LLMMessageToolCallSchema>;
export type LLMToolDefinition = z.infer<typeof LLMToolDefinitionSchema>;
export type LLMRequest = z.infer<typeof LLMRequestSchema>;

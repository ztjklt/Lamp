import { z } from "zod";
import { JsonObjectSchema, UUIDSchema } from "./Common.js";

export const TOOL_RISK_LEVELS = [
  "READ_ONLY",
  "LOW_MUTATION",
  "MEDIUM_MUTATION",
  "HIGH_MUTATION",
  "IRREVERSIBLE",
] as const;

export const ToolCallSchema = z.object({
  id: UUIDSchema,
  name: z.string().regex(/^[a-z][a-z0-9_]{1,79}$/),
  version: z.number().int().positive(),
  arguments: JsonObjectSchema,
  idempotencyKey: UUIDSchema.optional(),
}).strict();

export const ToolCallRecordSchema = z.object({
  call: ToolCallSchema,
  riskLevel: z.enum(TOOL_RISK_LEVELS),
  startedAt: z.string(),
  endedAt: z.string().optional(),
  status: z.enum(["requested", "succeeded", "failed", "denied", "confirmation_required"]),
  result: JsonObjectSchema.optional(),
  errorCode: z.string().optional(),
}).strict();

export type ToolCall = z.infer<typeof ToolCallSchema>;
export type ToolCallRecord = z.infer<typeof ToolCallRecordSchema>;

import { z } from "zod";
import { ERROR_CODES } from "../../errors/ErrorCode.js";
import { JsonObjectSchema, UUIDSchema } from "../schemas/Common.js";

export const PolicyDecisionSchema = z.object({
  decision: z.enum(["allow", "ask_user", "deny"]),
  policyId: z.string().min(1),
  reasonCode: z.string().regex(/^[A-Z][A-Z0-9_]*$/),
}).strict();

export const ToolResultSchema = z.object({
  callId: UUIDSchema,
  toolName: z.string().min(1),
  status: z.enum(["succeeded", "confirmation_required", "denied", "failed"]),
  output: JsonObjectSchema.optional(),
  policyDecision: PolicyDecisionSchema.optional(),
  error: z.object({
    code: z.enum(ERROR_CODES),
    message: z.string(),
    retryable: z.boolean(),
  }).strict().optional(),
}).strict();

export type PolicyDecision = z.infer<typeof PolicyDecisionSchema>;
export type ToolResult = z.infer<typeof ToolResultSchema>;

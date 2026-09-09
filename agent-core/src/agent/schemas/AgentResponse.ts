import { z } from "zod";
import { JsonObjectSchema, UUIDSchema } from "./Common.js";

export const AgentResponseSchema = z.object({
  runId: UUIDSchema,
  status: z.enum(["succeeded", "confirmation_required", "safe_aborted", "failed"]),
  message: z.string().max(8_000),
  proposal: JsonObjectSchema.optional(),
  pendingActionId: UUIDSchema.optional(),
  error: z.object({
    code: z.string(),
    message: z.string(),
    retryable: z.boolean(),
  }).strict().optional(),
}).strict();

export type AgentResponse = z.infer<typeof AgentResponseSchema>;

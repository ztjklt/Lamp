import { z } from "zod";
import { ConfidenceSchema, JsonObjectSchema } from "./Common.js";

export const AgentDecisionSchema = z.object({
  goal: z.string().min(1).max(200),
  action: z.string().min(1).max(120),
  reasonCodes: z.array(z.string().regex(/^[A-Z][A-Z0-9_]*$/)).max(20),
  confidence: ConfidenceSchema,
  expectedEffect: JsonObjectSchema,
}).strict();

export type AgentDecision = z.infer<typeof AgentDecisionSchema>;

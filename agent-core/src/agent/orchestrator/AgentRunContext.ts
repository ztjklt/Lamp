import { z } from "zod";
import { UUIDSchema } from "../schemas/Common.js";

export const AgentRunContextSchema = z.object({
  runId: UUIDSchema,
  traceId: UUIDSchema,
  userId: z.string().min(1),
  sessionId: z.string().min(1),
  requestId: z.string().min(1),
  stateSnapshotId: UUIDSchema.optional(),
  modelTurns: z.number().int().nonnegative(),
  toolCalls: z.number().int().nonnegative(),
  planningAttempts: z.number().int().nonnegative(),
  repairAttempts: z.number().int().nonnegative(),
  limits: z.object({
    maxModelTurns: z.number().int().positive(),
    maxToolCalls: z.number().int().nonnegative(),
    maxPlanningAttempts: z.number().int().positive(),
    maxRepairAttempts: z.number().int().nonnegative(),
    maxRunDurationMs: z.number().int().positive(),
  }).strict(),
}).strict();

export type AgentRunContext = z.infer<typeof AgentRunContextSchema>;

import { z } from "zod";
import { ConfidenceSchema, TimestampSchema } from "./Common.js";

export const INTENTS = [
  "create_task",
  "update_task",
  "plan_schedule",
  "replan_schedule",
  "query_schedule",
  "complete_task",
  "chat",
  "unknown",
] as const;

export const IntentSchema = z.object({
  intent: z.enum(INTENTS),
  confidence: ConfidenceSchema,
  entities: z.object({
    taskIds: z.array(z.string().min(1)).optional(),
    dateRange: z.object({
      start: TimestampSchema,
      end: TimestampSchema,
    }).refine(
      (range) => Date.parse(range.end) > Date.parse(range.start),
      "dateRange.end must be after start",
    ).optional(),
  }).strict(),
  requiresClarification: z.boolean(),
}).strict();

export type Intent = z.infer<typeof IntentSchema>;

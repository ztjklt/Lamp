import { z } from "zod";
import { TimeRangeSchema } from "../state/StateModels.js";
import { AgentDecisionSchema } from "./AgentDecision.js";
import { IntentSchema } from "./Intent.js";

const ActionBase = z.object({
  intent: IntentSchema,
  decision: AgentDecisionSchema,
});

export const AgentActionSchema = z.discriminatedUnion("type", [
  ActionBase.extend({
    type: z.literal("respond"),
    message: z.string().min(1).max(8_000),
  }).strict(),
  ActionBase.extend({
    type: z.literal("ask_user"),
    message: z.string().min(1).max(8_000),
  }).strict(),
  ActionBase.extend({
    type: z.literal("generate_plan"),
    planning: z.object({
      taskIds: z.array(z.uuid()).min(1).max(100),
      horizon: TimeRangeSchema,
      scope: z.enum(["local", "day", "multi_day", "full"]),
      candidateLimit: z.number().int().min(1).max(10).default(3),
      slotGranularityMinutes: z.union([z.literal(5), z.literal(10), z.literal(15), z.literal(30), z.literal(60)]).default(30),
      maximumDailyFocusMinutes: z.number().int().min(30).max(960).default(360),
    }).strict(),
  }).strict(),
]);

export type AgentAction = z.infer<typeof AgentActionSchema>;

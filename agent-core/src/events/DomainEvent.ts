import { z } from "zod";
import { TimeRangeSchema, UTCInstantSchema } from "../agent/state/StateModels.js";
import { UUIDSchema } from "../agent/schemas/Common.js";

const EventBase = z.object({
  eventId: UUIDSchema,
  userId: z.string().min(1),
  occurredAt: UTCInstantSchema,
});

const TaskEventPayload = z.object({ taskId: UUIDSchema }).strict();

export const DomainEventSchema = z.discriminatedUnion("type", [
  EventBase.extend({
    type: z.literal("TASK_COMPLETED_EARLY"),
    payload: TaskEventPayload.extend({ freedMinutes: z.number().int().nonnegative() }).strict(),
  }).strict(),
  EventBase.extend({
    type: z.literal("TASK_INCOMPLETE"),
    payload: TaskEventPayload.extend({ additionalMinutes: z.number().int().nonnegative().default(0) }).strict(),
  }).strict(),
  EventBase.extend({ type: z.literal("TASK_OVERDUE"), payload: TaskEventPayload }).strict(),
  EventBase.extend({ type: z.literal("NEW_TASK_CREATED"), payload: TaskEventPayload }).strict(),
  EventBase.extend({
    type: z.literal("EVENT_ADDED"),
    payload: z.object({ calendarEventId: UUIDSchema, range: TimeRangeSchema }).strict(),
  }).strict(),
  EventBase.extend({
    type: z.literal("EVENT_REMOVED"),
    payload: z.object({ calendarEventId: UUIDSchema, previousRange: TimeRangeSchema }).strict(),
  }).strict(),
  EventBase.extend({
    type: z.literal("USER_DELAYED"),
    payload: z.object({ delayMinutes: z.number().int().positive().max(1_440), taskId: UUIDSchema.optional() }).strict(),
  }).strict(),
  EventBase.extend({
    type: z.literal("USER_CANCELLED"),
    payload: z.object({ taskId: UUIDSchema.optional(), blockId: UUIDSchema.optional() }).strict()
      .refine((value) => value.taskId !== undefined || value.blockId !== undefined, "taskId or blockId is required"),
  }).strict(),
  EventBase.extend({
    type: z.literal("DEADLINE_CHANGED"),
    payload: TaskEventPayload.extend({ previousDeadline: UTCInstantSchema.nullable(), deadline: UTCInstantSchema.nullable() }).strict(),
  }).strict(),
  EventBase.extend({
    type: z.literal("PRIORITY_CHANGED"),
    payload: TaskEventPayload.extend({ previousImportance: z.number().int().min(1).max(5), importance: z.number().int().min(1).max(5) }).strict(),
  }).strict(),
  EventBase.extend({
    type: z.literal("USER_REQUEST_REPLAN"),
    payload: z.object({
      scope: z.enum(["local", "day", "multi_day", "full"]).optional(),
      taskIds: z.array(UUIDSchema).max(100).optional(),
    }).strict(),
  }).strict(),
]);

export type DomainEvent = z.infer<typeof DomainEventSchema>;

export function freezeDomainEvent(event: DomainEvent): Readonly<DomainEvent> {
  return deepFreeze(structuredClone(event));
}

function deepFreeze<T>(value: T): T {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    for (const child of Object.values(value)) deepFreeze(child);
    Object.freeze(value);
  }
  return value;
}

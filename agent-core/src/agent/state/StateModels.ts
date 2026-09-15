import { z } from "zod";
import { JsonObjectSchema, UUIDSchema } from "../schemas/Common.js";

export const UTCInstantSchema = z.iso.datetime().refine(
  (value) => value.endsWith("Z"),
  "timestamp must be normalized to UTC",
);

export const TimeRangeSchema = z.object({
  start: UTCInstantSchema,
  end: UTCInstantSchema,
}).strict().refine(
  (range) => Date.parse(range.end) > Date.parse(range.start),
  "time range end must be after start",
);

const VersionSchema = z.number().int().nonnegative();
const LocalTimeSchema = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/);

export const UserStateSchema = z.object({
  id: z.string().min(1),
  timezone: z.string().min(1).max(80),
  locale: z.string().min(1).max(40),
  version: VersionSchema,
}).strict();

export const GoalStateSchema = z.object({
  id: UUIDSchema,
  parentId: UUIDSchema.nullable(),
  title: z.string().min(1).max(240),
  detail: z.string().max(4_000),
  importance: z.number().int().min(1).max(5),
  deadline: UTCInstantSchema.nullable(),
  status: z.enum(["active", "paused", "completed", "archived"]),
  version: VersionSchema,
}).strict();

export const TaskStateSchema = z.object({
  id: UUIDSchema,
  goalId: UUIDSchema.nullable(),
  title: z.string().min(1).max(240),
  detail: z.string().max(4_000),
  importance: z.number().int().min(1).max(5),
  deadline: UTCInstantSchema.nullable(),
  estimatedMinutes: z.number().int().nonnegative(),
  remainingMinutes: z.number().int().nonnegative(),
  isPaused: z.boolean(),
  isSplittable: z.boolean(),
  minimumSessionMinutes: z.number().int().positive(),
  maximumSessionMinutes: z.number().int().positive(),
  preferredPeriods: z.array(z.enum(["morning", "afternoon", "evening"])),
  dependencyIds: z.array(UUIDSchema),
  availableWindows: z.array(TimeRangeSchema),
  version: VersionSchema,
}).strict().refine(
  (task) => task.maximumSessionMinutes >= task.minimumSessionMinutes,
  "maximumSessionMinutes must be at least minimumSessionMinutes",
);

export const ScheduleBlockStateSchema = z.object({
  id: UUIDSchema,
  taskId: UUIDSchema.nullable(),
  title: z.string().min(1).max(240),
  startsAt: UTCInstantSchema,
  endsAt: UTCInstantSchema,
  kind: z.enum(["fixed", "focus", "break", "free"]),
  state: z.enum(["planned", "active", "completed", "partial", "missed", "cancelled"]),
  locked: z.boolean(),
  provenance: z.string().min(1).max(500),
  reasonCodes: z.array(z.string().regex(/^[A-Z][A-Z0-9_]*$/)).max(20),
  revision: VersionSchema,
}).strict().refine(
  (block) => Date.parse(block.endsAt) > Date.parse(block.startsAt),
  "schedule block must have positive duration",
);

export const CalendarEventStateSchema = z.object({
  id: UUIDSchema,
  externalId: z.string().min(1).max(500),
  provider: z.string().min(1).max(100),
  title: z.string().min(1).max(500),
  startsAt: UTCInstantSchema,
  endsAt: UTCInstantSchema,
  allDay: z.boolean(),
  locked: z.literal(true),
  status: z.enum(["confirmed", "tentative", "cancelled"]),
  version: VersionSchema,
}).strict().refine(
  (event) => Date.parse(event.endsAt) > Date.parse(event.startsAt),
  "calendar event must have positive duration",
);

export const PreferenceStateSchema = z.object({
  userId: z.string().min(1),
  preferredSleepTime: LocalTimeSchema.nullable(),
  preferredWakeTime: LocalTimeSchema.nullable(),
  defaultReminderMinutes: z.number().int().nonnegative(),
  preferredFocusMinutes: z.number().int().positive(),
  preferredBreakMinutes: z.number().int().nonnegative(),
  morningStudyPreference: z.number().min(0).max(1),
  eveningStudyPreference: z.number().min(0).max(1),
  version: VersionSchema,
}).strict();

export const EnergyStateSchema = z.object({
  level: z.number().min(0).max(1),
  source: z.enum(["user_explicit", "user_inferred", "default"]),
  capturedAt: UTCInstantSchema,
  expiresAt: UTCInstantSchema.nullable(),
}).strict().refine(
  (energy) => energy.expiresAt === null || Date.parse(energy.expiresAt) > Date.parse(energy.capturedAt),
  "energy expiration must be after capture",
);

export const ConstraintStateSchema = z.object({
  id: UUIDSchema,
  type: z.enum([
    "NO_OVERLAP",
    "LOCKED_EVENT_IMMUTABLE",
    "BEFORE_DEADLINE",
    "DEPENDENCY_ORDER",
    "MINIMUM_DURATION",
    "AVAILABLE_WINDOW",
    "SLEEP_BOUNDARY",
    "FIXED_EVENT_PROTECTION",
    "USER_BLOCKED_TIME",
  ]),
  parameters: JsonObjectSchema,
  source: z.enum(["system", "user", "calendar", "domain"]),
  locked: z.boolean(),
  version: VersionSchema,
}).strict();

export type TimeRange = z.infer<typeof TimeRangeSchema>;
export type UserState = z.infer<typeof UserStateSchema>;
export type GoalState = z.infer<typeof GoalStateSchema>;
export type TaskState = z.infer<typeof TaskStateSchema>;
export type ScheduleBlockState = z.infer<typeof ScheduleBlockStateSchema>;
export type CalendarEventState = z.infer<typeof CalendarEventStateSchema>;
export type PreferenceState = z.infer<typeof PreferenceStateSchema>;
export type EnergyState = z.infer<typeof EnergyStateSchema>;
export type ConstraintState = z.infer<typeof ConstraintStateSchema>;

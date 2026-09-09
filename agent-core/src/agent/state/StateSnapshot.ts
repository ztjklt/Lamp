import { z } from "zod";
import { UUIDSchema } from "../schemas/Common.js";
import {
  CalendarEventStateSchema,
  ConstraintStateSchema,
  EnergyStateSchema,
  GoalStateSchema,
  PreferenceStateSchema,
  ScheduleBlockStateSchema,
  TaskStateSchema,
  TimeRangeSchema,
  UTCInstantSchema,
  UserStateSchema,
} from "./StateModels.js";

export const StateSnapshotSchema = z.object({
  snapshotId: UUIDSchema,
  userId: z.string().min(1),
  sourceRevision: z.number().int().nonnegative(),
  capturedAt: UTCInstantSchema,
  now: UTCInstantSchema,
  timezone: z.string().min(1).max(80),
  user: UserStateSchema,
  goals: z.array(GoalStateSchema),
  activeTasks: z.array(TaskStateSchema),
  schedule: z.array(ScheduleBlockStateSchema),
  upcomingEvents: z.array(CalendarEventStateSchema),
  preferences: PreferenceStateSchema,
  energy: EnergyStateSchema.nullable(),
  planningHorizon: TimeRangeSchema,
  lockedConstraints: z.array(ConstraintStateSchema),
}).strict().superRefine((snapshot, context) => {
  if (snapshot.userId !== snapshot.user.id || snapshot.userId !== snapshot.preferences.userId) {
    context.addIssue({
      code: "custom",
      path: ["userId"],
      message: "snapshot records must belong to the requested user",
    });
  }
  if (snapshot.timezone !== snapshot.user.timezone) {
    context.addIssue({
      code: "custom",
      path: ["timezone"],
      message: "snapshot timezone must match user timezone",
    });
  }
  if (snapshot.lockedConstraints.some((constraint) => !constraint.locked)) {
    context.addIssue({
      code: "custom",
      path: ["lockedConstraints"],
      message: "lockedConstraints may only contain locked constraints",
    });
  }
  const horizonStart = Date.parse(snapshot.planningHorizon.start);
  const horizonEnd = Date.parse(snapshot.planningHorizon.end);
  const outsideHorizon = [
    ...snapshot.schedule.map((block) => ({ start: block.startsAt, end: block.endsAt })),
    ...snapshot.upcomingEvents.map((event) => ({ start: event.startsAt, end: event.endsAt })),
  ].some((item) => Date.parse(item.start) >= horizonEnd || Date.parse(item.end) <= horizonStart);
  if (outsideHorizon) {
    context.addIssue({
      code: "custom",
      path: ["planningHorizon"],
      message: "schedule and calendar records must intersect the planning horizon",
    });
  }
});

export type StateSnapshot = z.infer<typeof StateSnapshotSchema>;

export function freezeStateSnapshot(snapshot: StateSnapshot): Readonly<StateSnapshot> {
  return deepFreeze(structuredClone(snapshot));
}

function deepFreeze<T>(value: T): T {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    for (const child of Object.values(value)) deepFreeze(child);
    Object.freeze(value);
  }
  return value;
}

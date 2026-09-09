import { z } from "zod";
import {
  CalendarEventStateSchema,
  ConstraintStateSchema,
  EnergyStateSchema,
  GoalStateSchema,
  PreferenceStateSchema,
  ScheduleBlockStateSchema,
  TaskStateSchema,
  TimeRangeSchema,
  UserStateSchema,
  type TimeRange,
  type UserState,
} from "../../agent/state/StateModels.js";
import type { StateSnapshot } from "../../agent/state/StateSnapshot.js";

export interface UserRepository {
  getById(userId: string): Promise<UserState | null>;
}

export interface StateReadRequest {
  userId: string;
  horizon: TimeRange;
  expectedUserVersion: number;
}

export const StateSourceDataSchema = z.object({
  userVersion: z.number().int().nonnegative(),
  sourceRevision: z.number().int().nonnegative(),
  goals: z.array(GoalStateSchema),
  activeTasks: z.array(TaskStateSchema),
  schedule: z.array(ScheduleBlockStateSchema),
  upcomingEvents: z.array(CalendarEventStateSchema),
  preferences: PreferenceStateSchema,
  energy: EnergyStateSchema.nullable(),
  lockedConstraints: z.array(ConstraintStateSchema),
}).strict();

export type StateSourceData = z.infer<typeof StateSourceDataSchema>;

export interface StateReadRepository {
  readForSnapshot(request: StateReadRequest): Promise<StateSourceData>;
}

export interface StateSnapshotRepository {
  save(snapshot: Readonly<StateSnapshot>): Promise<void>;
  getById(snapshotId: string): Promise<Readonly<StateSnapshot> | null>;
}

export const UserRepositoryRecordSchema = UserStateSchema;
export const StateReadRangeSchema = TimeRangeSchema;

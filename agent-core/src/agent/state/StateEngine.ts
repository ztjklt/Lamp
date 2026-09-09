import { z } from "zod";
import { LampError } from "../../errors/LampError.js";
import type { Clock } from "../../infrastructure/clock/Clock.js";
import type { IdGenerator } from "../../infrastructure/id/IdGenerator.js";
import { TimeZoneService } from "../../infrastructure/time/TimeZoneService.js";
import {
  StateSourceDataSchema,
  type StateReadRepository,
  type StateSnapshotRepository,
  type UserRepository,
} from "../../domain/repositories/StateRepositories.js";
import { TimeRangeSchema, UserStateSchema, type TimeRange, type UserState } from "./StateModels.js";
import { freezeStateSnapshot, StateSnapshotSchema, type StateSnapshot } from "./StateSnapshot.js";

export interface StateEngineOptions {
  defaultHorizonDays: number;
  maximumConsistencyAttempts?: number;
}

export interface BuildStateSnapshotRequest {
  userId: string;
  horizonDays?: number;
}

export class StateEngine {
  private readonly maximumConsistencyAttempts: number;

  constructor(
    private readonly userRepository: UserRepository,
    private readonly stateRepository: StateReadRepository,
    private readonly snapshotRepository: StateSnapshotRepository,
    private readonly clock: Clock,
    private readonly ids: IdGenerator,
    private readonly timeZones: TimeZoneService,
    private readonly options: StateEngineOptions,
  ) {
    if (!Number.isInteger(options.defaultHorizonDays) || options.defaultHorizonDays < 1) {
      throw new LampError({
        code: "VALIDATION_ERROR",
        message: "defaultHorizonDays must be a positive integer",
      });
    }
    this.maximumConsistencyAttempts = options.maximumConsistencyAttempts ?? 2;
    if (!Number.isInteger(this.maximumConsistencyAttempts) || this.maximumConsistencyAttempts < 1) {
      throw new LampError({
        code: "VALIDATION_ERROR",
        message: "maximumConsistencyAttempts must be a positive integer",
      });
    }
  }

  async buildSnapshot(request: BuildStateSnapshotRequest): Promise<Readonly<StateSnapshot>> {
    const horizonDays = request.horizonDays ?? this.options.defaultHorizonDays;
    if (!Number.isInteger(horizonDays) || horizonDays < 1 || horizonDays > 90) {
      throw new LampError({
        code: "VALIDATION_ERROR",
        message: "horizonDays must be an integer between 1 and 90",
        safeMessage: "规划时间范围无效。",
        details: { horizonDays },
      });
    }

    const now = this.clock.now();
    for (let attempt = 1; attempt <= this.maximumConsistencyAttempts; attempt += 1) {
      const persistedUser = await this.readUser(request.userId);
      const timezone = this.timeZones.validate(persistedUser.timezone);
      const user = timezone === persistedUser.timezone
        ? persistedUser
        : { ...persistedUser, timezone };
      const horizon = TimeRangeSchema.parse({
        start: now.toString(),
        end: this.timeZones.addCalendarDaysFromStartOfDay(now, horizonDays, timezone).toString(),
      });
      const source = await this.readSource(request.userId, user, horizon);
      if (source.userVersion !== persistedUser.version) continue;

      const snapshotResult = StateSnapshotSchema.safeParse({
        snapshotId: this.ids.next(),
        userId: request.userId,
        sourceRevision: source.sourceRevision,
        capturedAt: now.toString(),
        now: now.toString(),
        timezone,
        user,
        goals: source.goals,
        activeTasks: source.activeTasks,
        schedule: source.schedule,
        upcomingEvents: source.upcomingEvents,
        preferences: source.preferences,
        energy: source.energy,
        planningHorizon: horizon,
        lockedConstraints: source.lockedConstraints,
      });
      if (!snapshotResult.success) {
        throw dataError("State snapshot failed validation", snapshotResult.error);
      }

      const snapshot = freezeStateSnapshot(snapshotResult.data);
      try {
        await this.snapshotRepository.save(snapshot);
      } catch (error) {
        throw dataError("State snapshot could not be persisted", error);
      }
      return snapshot;
    }

    throw new LampError({
      code: "STALE_STATE",
      message: "User state changed while building the snapshot",
      safeMessage: "状态正在变化，请重试。",
      retryable: true,
      statusCode: 409,
    });
  }

  private async readUser(userId: string): Promise<UserState> {
    let rawUser: UserState | null;
    try {
      rawUser = await this.userRepository.getById(userId);
    } catch (error) {
      throw dataError("User state could not be read", error);
    }
    if (rawUser === null) {
      throw new LampError({
        code: "AUTH_ERROR",
        message: `User ${userId} is unavailable in the authenticated context`,
        safeMessage: "无法读取当前用户状态。",
        statusCode: 403,
      });
    }
    const parsed = UserStateSchema.safeParse(rawUser);
    if (!parsed.success) throw dataError("User state failed validation", parsed.error);
    if (parsed.data.id !== userId) {
      throw new LampError({
        code: "AUTH_ERROR",
        message: "User repository returned data for a different user",
        safeMessage: "用户数据隔离校验失败。",
        statusCode: 403,
      });
    }
    return parsed.data;
  }

  private async readSource(userId: string, user: UserState, horizon: TimeRange) {
    let rawSource: unknown;
    try {
      rawSource = await this.stateRepository.readForSnapshot({
        userId,
        horizon,
        expectedUserVersion: user.version,
      });
    } catch (error) {
      if (error instanceof LampError) throw error;
      throw dataError("State source could not be read", error);
    }
    const parsed = StateSourceDataSchema.safeParse(rawSource);
    if (!parsed.success) throw dataError("State source failed validation", parsed.error);
    return parsed.data;
  }
}

function dataError(message: string, cause: unknown): LampError {
  return new LampError({
    code: "DATABASE_ERROR",
    message,
    safeMessage: "当前状态暂时无法读取或保存。",
    retryable: true,
    statusCode: 503,
    details: cause instanceof z.ZodError ? { issues: cause.issues } : {},
    cause,
  });
}

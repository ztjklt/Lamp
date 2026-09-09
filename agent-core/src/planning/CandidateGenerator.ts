import { Temporal } from "@js-temporal/polyfill";
import type { TaskState } from "../agent/state/StateModels.js";
import type { PlanningRequest, ProposedScheduleBlock, RawScheduleCandidate } from "./PlanningTypes.js";
import {
  blockedConstraintRanges,
  deterministicUuid,
  intersect,
  localPeriod,
  sleepRanges,
  subtractRanges,
  toRange,
  type NumericRange,
} from "./PlanningUtilities.js";

type PlacementStrategy = "preference" | "earliest" | "latest";

export class CandidateGenerator {
  generate(request: PlanningRequest): RawScheduleCandidate[] {
    const strategies: readonly PlacementStrategy[] = ["preference", "earliest", "latest"];
    const unique = new Map<string, RawScheduleCandidate>();
    for (const strategy of strategies) {
      const candidate = this.generateForStrategy(request, strategy);
      if (candidate === null) continue;
      const signature = candidate.blocks.map((block) => `${block.taskId}:${block.startsAt}:${block.endsAt}`).sort().join("|");
      if (!unique.has(signature)) unique.set(signature, candidate);
      if (unique.size >= request.candidateLimit) break;
    }
    return [...unique.values()];
  }

  private generateForStrategy(request: PlanningRequest, strategy: PlacementStrategy): RawScheduleCandidate | null {
    const horizon = toRange(request.horizon);
    const occupied = [
      ...request.state.schedule.filter((block) => block.kind !== "free" && !["cancelled", "missed"].includes(block.state)).map(toRange),
      ...request.state.upcomingEvents.filter((event) => event.status !== "cancelled").map(toRange),
      ...blockedConstraintRanges(request.state.lockedConstraints),
      ...sleepRanges(horizon, request.state.preferences, request.state.timezone),
    ];
    let freeRanges = subtractRanges(horizon, occupied);
    const taskById = new Map(request.state.activeTasks.map((task) => [task.id, task]));
    const tasks = this.orderTasks(request.taskIds.map((id) => taskById.get(id)).filter((task): task is TaskState => task !== undefined), strategy);
    if (tasks.length !== request.taskIds.length || tasks.some((task) => task.isPaused)) return null;

    const dailyUsage = this.existingDailyUsage(request);
    const blocks: ProposedScheduleBlock[] = [];
    for (const task of tasks) {
      const sessions = splitSessions(task, request.state.preferences.preferredFocusMinutes);
      if (sessions === null) return null;
      for (let sessionIndex = 0; sessionIndex < sessions.length; sessionIndex += 1) {
        const duration = sessions[sessionIndex];
        if (duration === undefined) return null;
        const placement = this.choosePlacement(freeRanges, task, duration, request, strategy, dailyUsage);
        if (placement === null) return null;
        const startsAt = Temporal.Instant.fromEpochMilliseconds(placement.start).toString();
        const endsAt = Temporal.Instant.fromEpochMilliseconds(placement.end).toString();
        const id = deterministicUuid(request.state.snapshotId, strategy, task.id, String(sessionIndex), startsAt, endsAt);
        blocks.push({
          id,
          taskId: task.id,
          title: task.title,
          startsAt,
          endsAt,
          replacesBlockId: null,
          reasonCodes: [strategy === "preference" ? "PREFERENCE_MATCH" : strategy === "latest" ? "DEADLINE_AWARE" : "EARLIEST_AVAILABLE"],
        });
        freeRanges = freeRanges.flatMap((range) => subtractRanges(range, [placement]));
        const day = localDateKey(placement.start, request.state.timezone);
        dailyUsage.set(day, (dailyUsage.get(day) ?? 0) + duration);
      }
    }
    blocks.sort((left, right) => Date.parse(left.startsAt) - Date.parse(right.startsAt) || left.taskId.localeCompare(right.taskId));
    const identity = blocks.map((block) => `${block.taskId}:${block.startsAt}:${block.endsAt}`).join("|");
    return { id: deterministicUuid(request.state.snapshotId, strategy, identity), blocks, changedExistingBlocks: 0 };
  }

  private orderTasks(tasks: TaskState[], strategy: PlacementStrategy): TaskState[] {
    const ids = new Set(tasks.map((task) => task.id));
    const remaining = new Map(tasks.map((task) => [task.id, task]));
    const ordered: TaskState[] = [];
    while (remaining.size > 0) {
      const ready = [...remaining.values()].filter((task) => task.dependencyIds.every((id) => !ids.has(id) || !remaining.has(id)));
      if (ready.length === 0) return [];
      ready.sort((left, right) => compareTasks(left, right, strategy));
      const next = ready[0];
      if (next === undefined) return [];
      ordered.push(next);
      remaining.delete(next.id);
    }
    return ordered;
  }

  private choosePlacement(
    freeRanges: readonly NumericRange[],
    task: TaskState,
    durationMinutes: number,
    request: PlanningRequest,
    strategy: PlacementStrategy,
    dailyUsage: ReadonlyMap<string, number>,
  ): NumericRange | null {
    const durationMs = durationMinutes * 60_000;
    const permitted = task.availableWindows.length === 0
      ? [...freeRanges]
      : freeRanges.flatMap((free) => task.availableWindows.flatMap((window) => {
        const value = intersect(free, toRange(window));
        return value === null ? [] : [value];
      }));
    const candidates: NumericRange[] = [];
    const step = request.slotGranularityMinutes * 60_000;
    for (const range of permitted) {
      const first = Math.ceil(range.start / step) * step;
      const last = Math.floor((range.end - durationMs) / step) * step;
      if (last < first) continue;
      if (strategy === "latest") {
        for (let start = last; start >= first; start -= step) candidates.push({ start, end: start + durationMs });
      } else {
        for (let start = first; start <= last; start += step) candidates.push({ start, end: start + durationMs });
      }
    }
    if (strategy === "preference") {
      candidates.sort((left, right) => {
        const leftMatch = task.preferredPeriods.includes(localPeriod(left.start, request.state.timezone) as "morning" | "afternoon" | "evening") ? 1 : 0;
        const rightMatch = task.preferredPeriods.includes(localPeriod(right.start, request.state.timezone) as "morning" | "afternoon" | "evening") ? 1 : 0;
        return rightMatch - leftMatch || left.start - right.start;
      });
    }
    return candidates.find((candidate) => {
      const day = localDateKey(candidate.start, request.state.timezone);
      return (dailyUsage.get(day) ?? 0) + durationMinutes <= request.maximumDailyFocusMinutes;
    }) ?? null;
  }

  private existingDailyUsage(request: PlanningRequest): Map<string, number> {
    const usage = new Map<string, number>();
    for (const block of request.state.schedule.filter((item) => item.kind === "focus" && !["cancelled", "missed"].includes(item.state))) {
      const day = localDateKey(Date.parse(block.startsAt), request.state.timezone);
      usage.set(day, (usage.get(day) ?? 0) + (Date.parse(block.endsAt) - Date.parse(block.startsAt)) / 60_000);
    }
    return usage;
  }
}

function splitSessions(task: TaskState, preferredFocusMinutes: number): number[] | null {
  if (task.remainingMinutes === 0) return [];
  if (!task.isSplittable) {
    return task.remainingMinutes >= task.minimumSessionMinutes && task.remainingMinutes <= task.maximumSessionMinutes
      ? [task.remainingMinutes] : null;
  }
  const target = Math.max(task.minimumSessionMinutes, Math.min(task.maximumSessionMinutes, preferredFocusMinutes));
  const sessions: number[] = [];
  let remaining = task.remainingMinutes;
  while (remaining > target) {
    let duration = target;
    if (remaining - duration < task.minimumSessionMinutes) duration = remaining - task.minimumSessionMinutes;
    if (duration < task.minimumSessionMinutes) return null;
    sessions.push(duration);
    remaining -= duration;
  }
  if (remaining > 0) {
    if (remaining < task.minimumSessionMinutes || remaining > task.maximumSessionMinutes) return null;
    sessions.push(remaining);
  }
  return sessions;
}

function compareTasks(left: TaskState, right: TaskState, strategy: PlacementStrategy): number {
  const leftDeadline = left.deadline === null ? Number.POSITIVE_INFINITY : Date.parse(left.deadline);
  const rightDeadline = right.deadline === null ? Number.POSITIVE_INFINITY : Date.parse(right.deadline);
  if (strategy === "latest") return rightDeadline - leftDeadline || right.importance - left.importance || left.id.localeCompare(right.id);
  return leftDeadline - rightDeadline || right.importance - left.importance || left.id.localeCompare(right.id);
}

function localDateKey(epochMilliseconds: number, timeZone: string): string {
  return Temporal.Instant.fromEpochMilliseconds(epochMilliseconds).toZonedDateTimeISO(timeZone).toPlainDate().toString();
}

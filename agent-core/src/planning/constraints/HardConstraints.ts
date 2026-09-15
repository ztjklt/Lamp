import { Temporal } from "@js-temporal/polyfill";
import type { ConstraintState, TaskState } from "../../agent/state/StateModels.js";
import type { PlanningRequest, ProposedScheduleBlock, ConstraintViolation, RawScheduleCandidate } from "../PlanningTypes.js";
import { blockedConstraintRanges, contains, overlaps, sleepRanges, toRange, type NumericRange } from "../PlanningUtilities.js";

export interface HardConstraint {
  readonly code: string;
  validate(candidate: RawScheduleCandidate, request: PlanningRequest): ConstraintViolation[];
}

function violation(
  code: string,
  message: string,
  blockIds: string[],
  taskId?: string,
  constraintId = `system:${code}`,
): ConstraintViolation {
  return { constraintId, code, message, blockIds: blockIds.slice(0, 20), ...(taskId === undefined ? {} : { taskId }) };
}

function blockRange(block: ProposedScheduleBlock): NumericRange {
  return { start: Date.parse(block.startsAt), end: Date.parse(block.endsAt) };
}

function taskMap(request: PlanningRequest): Map<string, TaskState> {
  return new Map(request.state.activeTasks.map((task) => [task.id, task]));
}

export class NoOverlapConstraint implements HardConstraint {
  readonly code = "NO_OVERLAP";
  validate(candidate: RawScheduleCandidate, request: PlanningRequest): ConstraintViolation[] {
    const violations: ConstraintViolation[] = [];
    const blocks = [...candidate.blocks].sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt));
    for (let index = 1; index < blocks.length; index += 1) {
      const previous = blocks[index - 1];
      const current = blocks[index];
      if (previous !== undefined && current !== undefined && overlaps(blockRange(previous), blockRange(current))) {
        violations.push(violation(this.code, "Proposed focus blocks overlap.", [previous.id, current.id]));
      }
    }
    const existingBlocks = request.state.schedule.filter((block) => block.kind !== "free" && !["cancelled", "missed"].includes(block.state));
    for (const block of candidate.blocks) {
      for (const existing of existingBlocks) {
        if (block.replacesBlockId !== existing.id && overlaps(blockRange(block), toRange(existing))) {
          violations.push(violation(this.code, "Proposed block overlaps an existing schedule block.", [block.id, existing.id], block.taskId));
        }
      }
    }
    return violations;
  }
}

export class LockedEventImmutableConstraint implements HardConstraint {
  readonly code = "LOCKED_EVENT_IMMUTABLE";
  validate(candidate: RawScheduleCandidate, request: PlanningRequest): ConstraintViolation[] {
    const lockedIds = new Set(request.state.schedule.filter((block) => block.locked).map((block) => block.id));
    return candidate.blocks.flatMap((block) => block.replacesBlockId !== null && lockedIds.has(block.replacesBlockId)
      ? [violation(this.code, "A locked schedule block cannot be replaced.", [block.id, block.replacesBlockId], block.taskId)] : []);
  }
}

export class BeforeDeadlineConstraint implements HardConstraint {
  readonly code = "BEFORE_DEADLINE";
  validate(candidate: RawScheduleCandidate, request: PlanningRequest): ConstraintViolation[] {
    const tasks = taskMap(request);
    return candidate.blocks.flatMap((block) => {
      const deadline = tasks.get(block.taskId)?.deadline;
      return deadline !== null && deadline !== undefined && Date.parse(block.endsAt) > Date.parse(deadline)
        ? [violation(this.code, "Task block ends after its deadline.", [block.id], block.taskId)] : [];
    });
  }
}

export class DependencyOrderConstraint implements HardConstraint {
  readonly code = "DEPENDENCY_ORDER";
  validate(candidate: RawScheduleCandidate, request: PlanningRequest): ConstraintViolation[] {
    const tasks = taskMap(request);
    const selected = new Set(request.taskIds);
    const blocksByTask = new Map<string, ProposedScheduleBlock[]>();
    for (const block of candidate.blocks) blocksByTask.set(block.taskId, [...(blocksByTask.get(block.taskId) ?? []), block]);
    const violations: ConstraintViolation[] = [];
    for (const taskId of request.taskIds) {
      const task = tasks.get(taskId);
      if (task === undefined) continue;
      const childBlocks = blocksByTask.get(taskId) ?? [];
      for (const dependencyId of task.dependencyIds) {
        const dependency = tasks.get(dependencyId);
        if (dependency !== undefined && dependency.remainingMinutes > 0 && !selected.has(dependencyId)) {
          violations.push(violation(this.code, "An unfinished dependency is not included in the plan.", childBlocks.map((block) => block.id), taskId));
          continue;
        }
        if (!selected.has(dependencyId)) continue;
        const dependencyBlocks = blocksByTask.get(dependencyId) ?? [];
        const dependencyEnd = Math.max(...dependencyBlocks.map((block) => Date.parse(block.endsAt)));
        const childStart = Math.min(...childBlocks.map((block) => Date.parse(block.startsAt)));
        if (dependencyBlocks.length === 0 || childBlocks.length === 0 || dependencyEnd > childStart) {
          violations.push(violation(this.code, "Dependency work must finish before dependent work starts.", [...dependencyBlocks, ...childBlocks].map((block) => block.id), taskId));
        }
      }
    }
    return violations;
  }
}

export class MinimumDurationConstraint implements HardConstraint {
  readonly code = "MINIMUM_DURATION";
  validate(candidate: RawScheduleCandidate, request: PlanningRequest): ConstraintViolation[] {
    const tasks = taskMap(request);
    const violations: ConstraintViolation[] = [];
    for (const taskId of request.taskIds) {
      const task = tasks.get(taskId);
      if (task === undefined) continue;
      const blocks = candidate.blocks.filter((block) => block.taskId === taskId);
      const total = blocks.reduce((sum, block) => sum + (Date.parse(block.endsAt) - Date.parse(block.startsAt)) / 60_000, 0);
      const invalidSession = blocks.some((block) => {
        const duration = (Date.parse(block.endsAt) - Date.parse(block.startsAt)) / 60_000;
        return duration < task.minimumSessionMinutes || duration > task.maximumSessionMinutes;
      });
      if (total !== task.remainingMinutes || invalidSession || (!task.isSplittable && blocks.length > 1)) {
        violations.push(violation(this.code, "Task duration or session sizing is invalid.", blocks.map((block) => block.id), taskId));
      }
    }
    return violations;
  }
}

export class AvailableWindowConstraint implements HardConstraint {
  readonly code = "AVAILABLE_WINDOW";
  validate(candidate: RawScheduleCandidate, request: PlanningRequest): ConstraintViolation[] {
    const tasks = taskMap(request);
    return candidate.blocks.flatMap((block) => {
      const windows = tasks.get(block.taskId)?.availableWindows ?? [];
      return windows.length > 0 && !windows.some((window) => contains(toRange(window), blockRange(block)))
        ? [violation(this.code, "Task block is outside its available windows.", [block.id], block.taskId)] : [];
    });
  }
}

export class SleepBoundaryConstraint implements HardConstraint {
  readonly code = "SLEEP_BOUNDARY";
  validate(candidate: RawScheduleCandidate, request: PlanningRequest): ConstraintViolation[] {
    const ranges = sleepRanges(toRange(request.horizon), request.state.preferences, request.state.timezone);
    return candidate.blocks.flatMap((block) => ranges.some((range) => overlaps(range, blockRange(block)))
      ? [violation(this.code, "Task block overlaps the configured sleep boundary.", [block.id], block.taskId)] : []);
  }
}

export class FixedEventProtectionConstraint implements HardConstraint {
  readonly code = "FIXED_EVENT_PROTECTION";
  validate(candidate: RawScheduleCandidate, request: PlanningRequest): ConstraintViolation[] {
    const fixed = [
      ...request.state.schedule.filter((block) => block.kind === "fixed" && !["cancelled", "missed"].includes(block.state))
        .map((block) => ({ id: block.id, range: toRange(block) })),
      ...request.state.upcomingEvents.filter((event) => event.status !== "cancelled")
        .map((event) => ({ id: event.id, range: toRange(event) })),
    ];
    return candidate.blocks.flatMap((block) => fixed.flatMap((item) => overlaps(item.range, blockRange(block))
      ? [violation(this.code, "Task block overlaps a fixed event.", [block.id, item.id], block.taskId)] : []));
  }
}

export class UserBlockedTimeConstraint implements HardConstraint {
  readonly code = "USER_BLOCKED_TIME";
  validate(candidate: RawScheduleCandidate, request: PlanningRequest): ConstraintViolation[] {
    const constraints = request.state.lockedConstraints.filter((constraint) => constraint.type === this.code);
    return candidate.blocks.flatMap((block) => constraints.flatMap((constraint) => {
      const range = rangeFromConstraint(constraint);
      return range !== null && overlaps(range, blockRange(block))
        ? [violation(this.code, "Task block overlaps user-blocked time.", [block.id], block.taskId, constraint.id)] : [];
    }));
  }
}

export class MaximumWorkloadConstraint implements HardConstraint {
  readonly code = "MAXIMUM_WORKLOAD";
  validate(candidate: RawScheduleCandidate, request: PlanningRequest): ConstraintViolation[] {
    const totals = new Map<string, number>();
    for (const block of request.state.schedule.filter((item) => item.kind === "focus" && !["cancelled", "missed"].includes(item.state))) {
      addDailyMinutes(totals, toRange(block), request.state.timezone);
    }
    for (const block of candidate.blocks) addDailyMinutes(totals, blockRange(block), request.state.timezone);
    const overloadedDays = [...totals]
      .filter(([, total]) => total > request.maximumDailyFocusMinutes)
      .map(([day]) => day)
      .sort();
    return overloadedDays.map((day) => violation(
      this.code,
      `Daily focus workload exceeds the configured maximum on ${day}.`,
      candidate.blocks.filter((block) => localDate(block.startsAt, request.state.timezone) === day).map((block) => block.id),
    ));
  }
}

function addDailyMinutes(totals: Map<string, number>, range: NumericRange, timeZone: string): void {
  let cursor = Temporal.Instant.fromEpochMilliseconds(range.start);
  const end = Temporal.Instant.fromEpochMilliseconds(range.end);
  while (Temporal.Instant.compare(cursor, end) < 0) {
    const zoned = cursor.toZonedDateTimeISO(timeZone);
    const nextDay = zoned.startOfDay().add({ days: 1 }).toInstant();
    const segmentEnd = Temporal.Instant.compare(nextDay, end) < 0 ? nextDay : end;
    const day = zoned.toPlainDate().toString();
    totals.set(day, (totals.get(day) ?? 0) + (segmentEnd.epochMilliseconds - cursor.epochMilliseconds) / 60_000);
    cursor = segmentEnd;
  }
}

function localDate(instant: string, timeZone: string): string {
  return Temporal.Instant.from(instant).toZonedDateTimeISO(timeZone).toPlainDate().toString();
}

function rangeFromConstraint(constraint: ConstraintState): NumericRange | null {
  const ranges = blockedConstraintRanges([constraint]);
  return ranges[0] ?? null;
}

export const DEFAULT_HARD_CONSTRAINTS: readonly HardConstraint[] = Object.freeze([
  new NoOverlapConstraint(),
  new LockedEventImmutableConstraint(),
  new BeforeDeadlineConstraint(),
  new DependencyOrderConstraint(),
  new MinimumDurationConstraint(),
  new AvailableWindowConstraint(),
  new SleepBoundaryConstraint(),
  new FixedEventProtectionConstraint(),
  new UserBlockedTimeConstraint(),
  new MaximumWorkloadConstraint(),
]);

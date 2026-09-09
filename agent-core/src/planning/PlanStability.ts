import type { ScheduleBlockState } from "../agent/state/StateModels.js";
import { ProposedScheduleBlockSchema, type ProposedScheduleBlock } from "./PlanningTypes.js";
import { PlanChangeSchema, type PlanChange } from "./ReplanningTypes.js";

export interface StabilityResult {
  blocks: ProposedScheduleBlock[];
  changes: PlanChange[];
  scheduleChangeCost: number;
  changedExistingBlocks: number;
}

export class PlanStability {
  compare(
    previousBlocks: readonly ScheduleBlockState[],
    proposedBlocks: readonly ProposedScheduleBlock[],
    reasonCodes: readonly string[],
  ): StabilityResult {
    const previous = [...previousBlocks].sort(compareBlockTime);
    const proposed = [...proposedBlocks].sort(compareBlockTime);
    const usedPrevious = new Set<number>();
    const adjusted: ProposedScheduleBlock[] = [];
    const changes: PlanChange[] = [];

    for (const next of proposed) {
      let previousIndex = previous.findIndex((old, index) => !usedPrevious.has(index) && old.taskId === next.taskId &&
        old.startsAt === next.startsAt && old.endsAt === next.endsAt);
      if (previousIndex < 0) {
        const compatible = previous.map((old, index) => ({ old, index }))
          .filter(({ old, index }) => !usedPrevious.has(index) && old.taskId === next.taskId)
          .sort((left, right) => Math.abs(Date.parse(left.old.startsAt) - Date.parse(next.startsAt)) -
            Math.abs(Date.parse(right.old.startsAt) - Date.parse(next.startsAt)) || left.index - right.index);
        previousIndex = compatible[0]?.index ?? -1;
      }
      const old = previousIndex < 0 ? undefined : previous[previousIndex];
      if (old === undefined) {
        adjusted.push(next);
        changes.push(PlanChangeSchema.parse({
          type: "ADD",
          taskId: next.taskId,
          proposedBlockId: next.id,
          proposedRange: proposedRange(next),
          cost: 2,
          reasonCodes: [...reasonCodes, "BLOCK_ADDED"],
        }));
        continue;
      }
      usedPrevious.add(previousIndex);
      const replacement = ProposedScheduleBlockSchema.parse({ ...next, replacesBlockId: old.id });
      adjusted.push(replacement);
      const sameStart = old.startsAt === next.startsAt;
      const sameEnd = old.endsAt === next.endsAt;
      const oldMinutes = duration(old);
      const nextMinutes = duration(next);
      const type = sameStart && sameEnd ? "UNCHANGED" : oldMinutes === nextMinutes ? "MOVE" : sameStart ? "RESIZE" : "MOVE";
      const shiftHours = Math.abs(Date.parse(old.startsAt) - Date.parse(next.startsAt)) / 3_600_000;
      const resizeHours = Math.abs(oldMinutes - nextMinutes) / 60;
      const cost = type === "UNCHANGED" ? 0 : round(1 + Math.min(2, shiftHours) + resizeHours);
      changes.push(PlanChangeSchema.parse({
        type,
        taskId: next.taskId,
        previousBlockId: old.id,
        proposedBlockId: next.id,
        previousRange: previousRange(old),
        proposedRange: proposedRange(next),
        cost,
        reasonCodes: type === "UNCHANGED"
          ? ["BLOCK_PRESERVED"]
          : [...reasonCodes, type === "RESIZE" ? "BLOCK_RESIZED" : "BLOCK_MOVED", ...(oldMinutes === nextMinutes ? [] : ["DURATION_CHANGED"])],
      }));
    }

    for (let index = 0; index < previous.length; index += 1) {
      if (usedPrevious.has(index)) continue;
      const old = previous[index];
      if (old === undefined) continue;
      changes.push(PlanChangeSchema.parse({
        type: "REMOVE",
        ...(old.taskId === null ? {} : { taskId: old.taskId }),
        previousBlockId: old.id,
        previousRange: previousRange(old),
        cost: 2,
        reasonCodes: [...reasonCodes, "BLOCK_REMOVED"],
      }));
    }
    const scheduleChangeCost = round(changes.reduce((sum, change) => sum + change.cost, 0));
    return {
      blocks: adjusted,
      changes,
      scheduleChangeCost,
      changedExistingBlocks: changes.filter((change) => change.type !== "UNCHANGED").length,
    };
  }
}

function previousRange(block: ScheduleBlockState): { start: string; end: string } {
  return { start: block.startsAt, end: block.endsAt };
}

function proposedRange(block: ProposedScheduleBlock): { start: string; end: string } {
  return { start: block.startsAt, end: block.endsAt };
}

function duration(block: { startsAt: string; endsAt: string }): number {
  return (Date.parse(block.endsAt) - Date.parse(block.startsAt)) / 60_000;
}

function compareBlockTime(left: { startsAt: string; id: string }, right: { startsAt: string; id: string }): number {
  return Date.parse(left.startsAt) - Date.parse(right.startsAt) || left.id.localeCompare(right.id);
}

function round(value: number): number {
  return Math.round(value * 1_000) / 1_000;
}

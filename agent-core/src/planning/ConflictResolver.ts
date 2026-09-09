import type { ScheduleBlockState, TimeRange } from "../agent/state/StateModels.js";
import type { StateSnapshot } from "../agent/state/StateSnapshot.js";
import type { DomainEvent } from "../events/DomainEvent.js";
import { rangeForScope } from "./ReplanningRanges.js";
import type { ReplanningDecision, ReplanningScope } from "./ReplanningTypes.js";

export interface ReplanningImpact {
  scope: ReplanningScope;
  affectedRange: TimeRange;
  taskIds: string[];
  mutableBlocks: ScheduleBlockState[];
  protectedBlocks: ScheduleBlockState[];
  reasonCodes: string[];
}

export class ConflictResolver {
  resolve(
    event: DomainEvent,
    state: Readonly<StateSnapshot>,
    decision: Extract<ReplanningDecision, { action: "replan" }>,
    scope: ReplanningScope = decision.scope,
  ): ReplanningImpact {
    const affectedRange = scope === decision.scope ? decision.affectedRange : rangeForScope(scope, event, state);
    const taskIds = this.expandDependencies(new Set(decision.affectedTaskIds), state);
    const expanded = this.expandDependencies(taskIds, state);
    const mutableBlocks = state.schedule.filter((block) => block.taskId !== null && expanded.has(block.taskId) &&
      !block.locked && block.kind === "focus" && !["completed", "cancelled"].includes(block.state) &&
      intersectsRange(affectedRange, block));
    const protectedBlocks = state.schedule.filter((block) => block.locked || block.kind === "fixed");
    return {
      scope,
      affectedRange,
      taskIds: [...expanded].sort(),
      mutableBlocks,
      protectedBlocks,
      reasonCodes: [
        ...decision.reasonCodes,
        ...(scope === decision.scope ? [] : ["REPLANNING_SCOPE_EXPANDED"]),
      ],
    };
  }

  private expandDependencies(initial: Set<string>, state: Readonly<StateSnapshot>): Set<string> {
    const active = new Map(state.activeTasks.filter((task) => !task.isPaused).map((task) => [task.id, task]));
    const result = new Set([...initial].filter((id) => active.has(id)));
    let changed = true;
    while (changed) {
      changed = false;
      for (const task of active.values()) {
        const related = result.has(task.id) || task.dependencyIds.some((dependencyId) => result.has(dependencyId));
        if (related && !result.has(task.id)) {
          result.add(task.id);
          changed = true;
        }
        if (result.has(task.id)) {
          for (const dependencyId of task.dependencyIds) {
            if (active.has(dependencyId) && !result.has(dependencyId)) {
              result.add(dependencyId);
              changed = true;
            }
          }
        }
      }
    }
    return result;
  }
}

function intersectsRange(range: TimeRange, block: ScheduleBlockState): boolean {
  return Date.parse(range.start) < Date.parse(block.endsAt) && Date.parse(range.end) > Date.parse(block.startsAt);
}

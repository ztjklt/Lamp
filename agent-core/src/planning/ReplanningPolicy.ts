import type { StateSnapshot } from "../agent/state/StateSnapshot.js";
import type { DomainEvent } from "../events/DomainEvent.js";
import { rangeForScope } from "./ReplanningRanges.js";
import { ReplanningDecisionSchema, type ReplanningDecision, type ReplanningScope } from "./ReplanningTypes.js";

export class ReplanningPolicy {
  evaluate(event: DomainEvent, state: Readonly<StateSnapshot>): ReplanningDecision {
    const affectedTaskIds = this.affectedTasks(event, state);
    if (event.type === "TASK_COMPLETED_EARLY") {
      return ReplanningDecisionSchema.parse({ action: "no_replan", reasonCodes: ["EARLY_COMPLETION_CAN_LEAVE_FREE_CAPACITY"], confidence: 0.96 });
    }
    if (event.type === "EVENT_REMOVED") {
      return ReplanningDecisionSchema.parse({ action: "no_replan", reasonCodes: ["REMOVED_EVENT_ONLY_FREES_CAPACITY"], confidence: 0.92 });
    }
    if (event.type === "EVENT_ADDED" && affectedTaskIds.length === 0) {
      const overlapsProtected = state.schedule.some((block) => (block.locked || block.kind === "fixed") &&
        !["completed", "cancelled"].includes(block.state) && intersects(event.payload.range, block));
      return ReplanningDecisionSchema.parse({
        action: "no_replan",
        reasonCodes: [overlapsProtected ? "LOCKED_EVENT_CONFLICT_REQUIRES_USER" : "EVENT_DOES_NOT_DISRUPT_FLEXIBLE_WORK"],
        confidence: 0.98,
      });
    }
    if (event.type === "PRIORITY_CHANGED" && event.payload.previousImportance === event.payload.importance) {
      return ReplanningDecisionSchema.parse({ action: "no_replan", reasonCodes: ["PRIORITY_UNCHANGED"], confidence: 1 });
    }
    const scope = this.scope(event, state);
    return ReplanningDecisionSchema.parse({
      action: "replan",
      scope,
      affectedTaskIds,
      affectedRange: rangeForScope(scope, event, state),
      reasonCodes: [reasonFor(event.type)],
      confidence: event.type === "USER_REQUEST_REPLAN" ? 1 : 0.9,
    });
  }

  private scope(event: DomainEvent, state: Readonly<StateSnapshot>): ReplanningScope {
    switch (event.type) {
      case "TASK_INCOMPLETE":
      case "EVENT_ADDED":
      case "USER_DELAYED":
      case "USER_CANCELLED":
        return "local";
      case "TASK_OVERDUE":
      case "PRIORITY_CHANGED":
        return "day";
      case "NEW_TASK_CREATED": {
        const task = state.activeTasks.find((candidate) => candidate.id === event.payload.taskId);
        return task?.deadline !== null && task?.deadline !== undefined &&
          Date.parse(task.deadline) - Date.parse(state.now) <= 48 * 60 * 60_000 ? "day" : "multi_day";
      }
      case "DEADLINE_CHANGED":
        return event.payload.deadline !== null && Date.parse(event.payload.deadline) - Date.parse(state.now) <= 72 * 60 * 60_000
          ? "multi_day" : "day";
      case "USER_REQUEST_REPLAN":
        return event.payload.scope ?? "day";
      case "TASK_COMPLETED_EARLY":
      case "EVENT_REMOVED":
        return "local";
    }
  }

  private affectedTasks(event: DomainEvent, state: Readonly<StateSnapshot>): string[] {
    switch (event.type) {
      case "TASK_COMPLETED_EARLY":
      case "TASK_INCOMPLETE":
      case "TASK_OVERDUE":
      case "NEW_TASK_CREATED":
      case "DEADLINE_CHANGED":
      case "PRIORITY_CHANGED":
        return [event.payload.taskId];
      case "USER_DELAYED":
        return event.payload.taskId === undefined ? tasksAt(event.occurredAt, state) : [event.payload.taskId];
      case "USER_CANCELLED": {
        if (event.payload.taskId !== undefined) return [event.payload.taskId];
        const taskId = state.schedule.find((block) => block.id === event.payload.blockId)?.taskId;
        return taskId === null || taskId === undefined ? [] : [taskId];
      }
      case "EVENT_ADDED":
        return state.schedule.filter((block) => block.taskId !== null && !block.locked && block.kind === "focus" &&
          !["completed", "cancelled"].includes(block.state) && intersects(event.payload.range, block))
          .map((block) => block.taskId!).filter(unique);
      case "EVENT_REMOVED":
        return [];
      case "USER_REQUEST_REPLAN":
        return (event.payload.taskIds ?? state.activeTasks.filter((task) => !task.isPaused).map((task) => task.id)).filter(unique);
    }
  }
}

function tasksAt(instant: string, state: Readonly<StateSnapshot>): string[] {
  const time = Date.parse(instant);
  return state.schedule.filter((block) => block.taskId !== null && !block.locked &&
    Date.parse(block.startsAt) <= time && Date.parse(block.endsAt) > time)
    .map((block) => block.taskId!).filter(unique);
}

function intersects(range: { start: string; end: string }, block: { startsAt: string; endsAt: string }): boolean {
  return Date.parse(range.start) < Date.parse(block.endsAt) && Date.parse(range.end) > Date.parse(block.startsAt);
}

function unique(value: string, index: number, values: string[]): boolean {
  return values.indexOf(value) === index;
}

function reasonFor(type: DomainEvent["type"]): string {
  const reasons: Record<DomainEvent["type"], string> = {
    TASK_COMPLETED_EARLY: "TASK_COMPLETED_EARLY",
    TASK_INCOMPLETE: "TASK_INCOMPLETE_REQUIRES_REALLOCATION",
    TASK_OVERDUE: "TASK_OVERDUE_REQUIRES_REVIEW",
    NEW_TASK_CREATED: "NEW_TASK_REQUIRES_PLACEMENT",
    EVENT_ADDED: "NEW_EVENT_CONFLICT",
    EVENT_REMOVED: "EVENT_REMOVED",
    USER_DELAYED: "USER_DELAY_REQUIRES_LOCAL_SHIFT",
    USER_CANCELLED: "USER_CANCELLATION_AFFECTS_PLAN",
    DEADLINE_CHANGED: "DEADLINE_CHANGE_REQUIRES_REVIEW",
    PRIORITY_CHANGED: "PRIORITY_CHANGE_REQUIRES_REORDER",
    USER_REQUEST_REPLAN: "USER_REQUESTED_REPLAN",
  };
  return reasons[type];
}

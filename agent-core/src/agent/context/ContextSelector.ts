import type { StateSnapshot } from "../state/StateSnapshot.js";

export interface SelectedContext {
  tasks: Readonly<StateSnapshot["activeTasks"]>;
  schedule: Readonly<StateSnapshot["schedule"]>;
  events: Readonly<StateSnapshot["upcomingEvents"]>;
}

export class ContextSelector {
  select(state: Readonly<StateSnapshot>): SelectedContext {
    const tasks = [...state.activeTasks]
      .sort((left, right) => {
        const leftDeadline = left.deadline === null ? Number.POSITIVE_INFINITY : Date.parse(left.deadline);
        const rightDeadline = right.deadline === null ? Number.POSITIVE_INFINITY : Date.parse(right.deadline);
        return leftDeadline - rightDeadline || right.importance - left.importance || left.id.localeCompare(right.id);
      })
      .slice(0, 20);
    return {
      tasks,
      schedule: [...state.schedule].sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt)).slice(0, 30),
      events: [...state.upcomingEvents].sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt)).slice(0, 30),
    };
  }
}

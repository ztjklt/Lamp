import type { TaskState } from "../agent/state/StateModels.js";
import type { PlanningRequest, RawScheduleCandidate, ScoreBreakdown } from "./PlanningTypes.js";
import { localPeriod } from "./PlanningUtilities.js";

export interface PlanningWeights {
  urgency: number;
  priority: number;
  preference: number;
  energyMatch: number;
  completionProbability: number;
  contextSwitchPenalty: number;
  fragmentationPenalty: number;
  scheduleChangePenalty: number;
  lateNightPenalty: number;
}

export const DEFAULT_PLANNING_WEIGHTS: Readonly<PlanningWeights> = Object.freeze({
  urgency: 25,
  priority: 20,
  preference: 15,
  energyMatch: 10,
  completionProbability: 30,
  contextSwitchPenalty: 4,
  fragmentationPenalty: 3,
  scheduleChangePenalty: 8,
  lateNightPenalty: 12,
});

export class PlanScorer {
  constructor(private readonly weights: Readonly<PlanningWeights> = DEFAULT_PLANNING_WEIGHTS) {}

  score(candidate: RawScheduleCandidate, request: PlanningRequest): { score: number; breakdown: ScoreBreakdown } {
    const tasks = new Map(request.state.activeTasks.map((task) => [task.id, task]));
    const totalMinutes = candidate.blocks.reduce((sum, block) => sum + duration(block), 0);
    const weighted = (selector: (task: TaskState, startsAt: number) => number): number => totalMinutes === 0 ? 1 :
      candidate.blocks.reduce((sum, block) => {
        const task = tasks.get(block.taskId);
        return sum + (task === undefined ? 0 : selector(task, Date.parse(block.startsAt)) * duration(block));
      }, 0) / totalMinutes;

    const urgencyRatio = weighted((task, startsAt) => {
      if (task.deadline === null) return 0.4;
      const horizon = Math.max(1, Date.parse(task.deadline) - Date.parse(request.state.now));
      return Math.max(0, Math.min(1, 1 - (startsAt - Date.parse(request.state.now)) / horizon));
    });
    const priorityRatio = weighted((task) => task.importance / 5);
    const preferenceRatio = weighted((task, startsAt) => {
      if (task.preferredPeriods.length === 0) return 0.5;
      const period = localPeriod(startsAt, request.state.timezone);
      return period !== "night" && task.preferredPeriods.includes(period) ? 1 : 0;
    });
    const energyRatio = request.state.energy === null ? 0.5 : weighted((task) => 1 - Math.abs(request.state.energy!.level - task.importance / 5));
    const completionRatio = request.taskIds.length === 0 ? 1 : request.taskIds.filter((taskId) => {
      const task = tasks.get(taskId);
      if (task === undefined) return false;
      return candidate.blocks.filter((block) => block.taskId === taskId).reduce((sum, block) => sum + duration(block), 0) === task.remainingMinutes;
    }).length / request.taskIds.length;
    const ordered = [...candidate.blocks].sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt));
    let switches = 0;
    for (let index = 1; index < ordered.length; index += 1) {
      const previous = ordered[index - 1];
      const current = ordered[index];
      if (previous !== undefined && current !== undefined && previous.taskId !== current.taskId &&
        Date.parse(current.startsAt) - Date.parse(previous.endsAt) <= 30 * 60_000) switches += 1;
    }
    const extraFragments = Math.max(0, candidate.blocks.length - new Set(candidate.blocks.map((block) => block.taskId)).size);
    const lateNightRatio = totalMinutes === 0 ? 0 : candidate.blocks.reduce((sum, block) =>
      sum + (localPeriod(Date.parse(block.startsAt), request.state.timezone) === "night" ? duration(block) : 0), 0) / totalMinutes;

    const breakdown: ScoreBreakdown = {
      urgency: round(urgencyRatio * this.weights.urgency),
      priority: round(priorityRatio * this.weights.priority),
      preference: round(preferenceRatio * this.weights.preference),
      energyMatch: round(energyRatio * this.weights.energyMatch),
      completionProbability: round(completionRatio * this.weights.completionProbability),
      contextSwitchPenalty: round(switches * this.weights.contextSwitchPenalty),
      fragmentationPenalty: round(extraFragments * this.weights.fragmentationPenalty),
      scheduleChangePenalty: round((candidate.scheduleChangeCost ?? candidate.changedExistingBlocks) * this.weights.scheduleChangePenalty),
      lateNightPenalty: round(lateNightRatio * this.weights.lateNightPenalty),
    };
    const score = round(breakdown.urgency + breakdown.priority + breakdown.preference + breakdown.energyMatch +
      breakdown.completionProbability - breakdown.contextSwitchPenalty - breakdown.fragmentationPenalty -
      breakdown.scheduleChangePenalty - breakdown.lateNightPenalty);
    return { score, breakdown };
  }
}

function duration(block: { startsAt: string; endsAt: string }): number {
  return (Date.parse(block.endsAt) - Date.parse(block.startsAt)) / 60_000;
}

function round(value: number): number {
  return Math.round(value * 1_000) / 1_000;
}

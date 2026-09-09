import { Temporal } from "@js-temporal/polyfill";
import type { Clock } from "../infrastructure/clock/Clock.js";
import { LampError } from "../errors/LampError.js";
import type { PlanRevisionRepository } from "../domain/repositories/PlanRevisionRepository.js";
import { StateSnapshotSchema, type StateSnapshot } from "../agent/state/StateSnapshot.js";
import type { ScheduleBlockState, TaskState } from "../agent/state/StateModels.js";
import { deterministicUuid } from "./PlanningUtilities.js";
import type { SchedulingEngine } from "./SchedulingEngine.js";
import { PlanningRequestSchema, ProposedScheduleBlockSchema, type ScheduleCandidate } from "./PlanningTypes.js";
import { PlanValidator } from "./PlanValidator.js";
import { ConflictResolver, type ReplanningImpact } from "./ConflictResolver.js";
import { PlanStability, type StabilityResult } from "./PlanStability.js";
import { ReplanningPolicy } from "./ReplanningPolicy.js";
import {
  PlanRevisionSchema,
  ReplanningRequestSchema,
  ReplanningResultSchema,
  type ReplanningRequest,
  type ReplanningResult,
  type ReplanningScope,
} from "./ReplanningTypes.js";

export class ReplanningEngine {
  constructor(
    private readonly planner: SchedulingEngine,
    private readonly revisions: PlanRevisionRepository,
    private readonly clock: Clock,
    private readonly policy = new ReplanningPolicy(),
    private readonly conflicts = new ConflictResolver(),
    private readonly stability = new PlanStability(),
    private readonly validator = new PlanValidator(),
  ) {}

  async replan(rawRequest: unknown): Promise<ReplanningResult> {
    const request: ReplanningRequest = ReplanningRequestSchema.parse(rawRequest);
    const decision = this.policy.evaluate(request.event, request.state);
    if (decision.action === "no_replan") {
      return ReplanningResultSchema.parse({ status: "no_replan", decision, diagnostics: decision.reasonCodes });
    }

    const diagnostics: string[] = [];
    for (const scope of scopeLadder(decision.scope)) {
      const impact = this.conflicts.resolve(request.event, request.state, decision, scope);
      if (impact.taskIds.length === 0) {
        diagnostics.push(`${scope}:NO_AFFECTED_ACTIVE_TASKS`);
        continue;
      }
      const planningState = this.createPlanningState(request.state, impact, request.event);
      const planningRequest = PlanningRequestSchema.parse({
        state: planningState,
        taskIds: impact.taskIds,
        horizon: impact.affectedRange,
        scope,
        candidateLimit: request.candidateLimit,
        slotGranularityMinutes: request.slotGranularityMinutes,
        maximumDailyFocusMinutes: request.maximumDailyFocusMinutes,
      });
      const planned = this.planner.plan(planningRequest);
      diagnostics.push(`${scope}:${planned.status}`);
      if (planned.status !== "success") continue;

      const existingLayout = this.existingLayoutCandidate(impact, planningRequest, request.event.eventId);
      const sourceCandidates = existingLayout === null
        ? planned.candidates
        : [existingLayout, ...planned.candidates.filter((candidate) => blockSignature(candidate.blocks) !== blockSignature(existingLayout.blocks))];
      const stableCandidates = sourceCandidates.flatMap((candidate) => {
        const comparison = this.stability.compare(impact.mutableBlocks, candidate.blocks, impact.reasonCodes);
        const validated = this.validator.validate({
          id: candidate.id,
          blocks: comparison.blocks,
          changedExistingBlocks: comparison.changedExistingBlocks,
          scheduleChangeCost: comparison.scheduleChangeCost,
        }, planningRequest);
        return validated.valid && validated.candidate !== undefined
          ? [{ candidate: validated.candidate, comparison }] : [];
      }).sort((left, right) => right.candidate.score - left.candidate.score ||
        left.comparison.scheduleChangeCost - right.comparison.scheduleChangeCost ||
        left.candidate.id.localeCompare(right.candidate.id));
      const selected = stableCandidates[0];
      if (selected === undefined) {
        diagnostics.push(`${scope}:STABILITY_VALIDATION_FAILED`);
        continue;
      }
      const revision = await this.createRevision(request, decision.confidence, impact, selected.candidate, selected.comparison);
      await this.revisions.append(revision);
      return ReplanningResultSchema.parse({
        status: "proposal",
        decision: { ...decision, scope, affectedRange: impact.affectedRange },
        candidate: selected.candidate,
        revision,
        diagnostics,
      });
    }
    return ReplanningResultSchema.parse({ status: "no_feasible_plan", decision, diagnostics });
  }

  private createPlanningState(state: StateSnapshot, impact: ReplanningImpact, event: ReplanningRequest["event"]): StateSnapshot {
    const mutableIds = new Set(impact.mutableBlocks.map((block) => block.id));
    const schedule = state.schedule.filter((block) => !mutableIds.has(block.id));
    const activeTasks = state.activeTasks.map((task) => impact.taskIds.includes(task.id)
      ? { ...task, remainingMinutes: remainingAfterPreservedSchedule(task, schedule, state.now) }
      : task);
    const upcomingEvents = event.type === "EVENT_ADDED" &&
      !state.upcomingEvents.some((item) => item.id === event.payload.calendarEventId)
      ? [...state.upcomingEvents, {
        id: event.payload.calendarEventId,
        externalId: event.payload.calendarEventId,
        provider: "domain_event",
        title: "New calendar event",
        startsAt: event.payload.range.start,
        endsAt: event.payload.range.end,
        allDay: false,
        locked: true as const,
        status: "confirmed" as const,
        version: state.sourceRevision,
      }]
      : state.upcomingEvents;
    return StateSnapshotSchema.parse({ ...state, schedule, activeTasks, upcomingEvents });
  }

  private existingLayoutCandidate(
    impact: ReplanningImpact,
    planningRequest: ReturnType<typeof PlanningRequestSchema.parse>,
    eventId: string,
  ): ScheduleCandidate | null {
    if (impact.mutableBlocks.length === 0 || impact.mutableBlocks.some((block) => block.state === "missed")) return null;
    const blocks = impact.mutableBlocks.map((block) => ProposedScheduleBlockSchema.parse({
      id: deterministicUuid(eventId, block.id, "preserve"),
      taskId: block.taskId,
      title: block.title,
      startsAt: block.startsAt,
      endsAt: block.endsAt,
      replacesBlockId: block.id,
      reasonCodes: ["PLAN_STABILITY"],
    }));
    const raw = {
      id: deterministicUuid(eventId, "existing-layout", blockSignature(blocks)),
      blocks,
      changedExistingBlocks: 0,
      scheduleChangeCost: 0,
    };
    const validated = this.validator.validate(raw, planningRequest);
    return validated.valid ? validated.candidate ?? null : null;
  }

  private async createRevision(
    request: ReplanningRequest,
    decisionConfidence: number,
    impact: ReplanningImpact,
    candidate: ScheduleCandidate,
    comparison: StabilityResult,
  ) {
    const localDate = Temporal.Instant.from(request.state.now).toZonedDateTimeISO(request.state.timezone).toPlainDate().toString();
    const planId = request.planId ?? deterministicUuid(request.state.userId, localDate, "schedule-plan");
    const latest = await this.revisions.getLatest(planId);
    if (latest !== null && latest.userId !== request.state.userId) {
      throw new LampError({
        code: "AUTH_ERROR",
        message: "Plan ownership does not match the replanning user",
        safeMessage: "计划数据隔离校验失败。",
        statusCode: 403,
      });
    }
    const revisionNumber = (latest?.revision ?? 0) + 1;
    const risk = revisionRisk(impact.scope, comparison.changedExistingBlocks);
    return PlanRevisionSchema.parse({
      planId,
      revisionId: deterministicUuid(planId, String(revisionNumber), request.event.eventId),
      revision: revisionNumber,
      previousRevisionId: latest?.revisionId ?? null,
      status: "proposed",
      userId: request.state.userId,
      sourceEventId: request.event.eventId,
      createdAt: this.clock.now().toString(),
      createdFromState: request.state.snapshotId,
      baseStateRevision: request.state.sourceRevision,
      scope: impact.scope,
      blocks: candidate.blocks,
      changes: comparison.changes,
      score: candidate.score,
      scheduleChangeCost: comparison.scheduleChangeCost,
      risk,
      confidence: round(Math.max(0.5, decisionConfidence - Math.min(0.35, comparison.scheduleChangeCost * 0.03))),
      requiresConfirmation: risk !== "low",
    });
  }
}

function remainingAfterPreservedSchedule(task: TaskState, schedule: readonly ScheduleBlockState[], now: string): number {
  const preservedMinutes = schedule.filter((block) => block.taskId === task.id && block.kind === "focus" &&
    !["completed", "cancelled", "missed"].includes(block.state) && Date.parse(block.endsAt) > Date.parse(now))
    .reduce((sum, block) => sum + (Date.parse(block.endsAt) - Math.max(Date.parse(block.startsAt), Date.parse(now))) / 60_000, 0);
  return Math.max(0, task.remainingMinutes - Math.round(preservedMinutes));
}

function scopeLadder(initial: ReplanningScope): ReplanningScope[] {
  const scopes: ReplanningScope[] = ["local", "day", "multi_day", "full"];
  return scopes.slice(scopes.indexOf(initial));
}

function revisionRisk(scope: ReplanningScope, changedBlocks: number): "low" | "medium" | "high" {
  if (scope === "full" || changedBlocks > 5) return "high";
  if (scope === "local" && changedBlocks <= 2) return "low";
  return "medium";
}

function round(value: number): number {
  return Math.round(value * 1_000) / 1_000;
}

function blockSignature(blocks: readonly { taskId: string; startsAt: string; endsAt: string }[]): string {
  return blocks.map((block) => `${block.taskId}:${block.startsAt}:${block.endsAt}`).sort().join("|");
}

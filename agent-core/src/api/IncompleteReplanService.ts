import { createHash } from "node:crypto";
import { StateSnapshotSchema } from "../agent/state/StateSnapshot.js";
import { EventBus } from "../events/EventBus.js";
import { FixedClock } from "../infrastructure/clock/FixedClock.js";
import { InMemoryPlanRevisionRepository } from "../infrastructure/repositories/InMemoryPlanRevisionRepository.js";
import { ReplanningEngine } from "../planning/ReplanningEngine.js";
import type { ReplanningResult } from "../planning/ReplanningTypes.js";
import { SchedulingEngine } from "../planning/SchedulingEngine.js";
import {
  IncompleteReplanRequestSchema,
  IncompleteReplanResponseSchema,
  type IncompleteReplanRequest,
  type IncompleteReplanResponse,
} from "./IncompleteReplanContract.js";

export class IdempotencyConflictError extends Error {}

export class IncompleteReplanService {
  private readonly revisions = new InMemoryPlanRevisionRepository();
  private readonly completed = new Map<string, { digest: string; response: IncompleteReplanResponse }>();

  async createProposal(input: unknown, userId = "lamp-local-client"): Promise<IncompleteReplanResponse> {
    const request = IncompleteReplanRequestSchema.parse(input);
    const key = `${userId}:${request.eventId}`;
    const digest = requestDigest(request);
    const previous = this.completed.get(key);
    if (previous !== undefined) {
      if (previous.digest !== digest) throw new IdempotencyConflictError("event_id_reused_with_different_request");
      return structuredClone(previous.response);
    }

    const state = StateSnapshotSchema.parse({
      snapshotId: request.eventId,
      userId,
      sourceRevision: 0,
      capturedAt: request.occurredAt,
      now: request.occurredAt,
      timezone: request.timezone,
      user: { id: userId, timezone: request.timezone, locale: request.locale, version: 0 },
      goals: [],
      activeTasks: request.tasks.map((task) => ({
        ...task,
        remainingMinutes: task.id === request.taskId
          ? request.additionalMinutes + scheduledFutureMinutes(request, task.id)
          : task.remainingMinutes,
        version: 0,
      })),
      schedule: request.schedule.map((block) => ({
        ...block,
        reasonCodes: block.locked ? ["FIXED_EVENT_PROTECTION"] : [],
        revision: 0,
      })),
      upcomingEvents: [],
      preferences: {
        userId,
        preferredSleepTime: request.preferences.preferredSleepTime,
        preferredWakeTime: request.preferences.preferredWakeTime,
        defaultReminderMinutes: 5,
        preferredFocusMinutes: request.preferences.preferredFocusMinutes,
        preferredBreakMinutes: request.preferences.preferredBreakMinutes,
        morningStudyPreference: request.preferences.morningStudyPreference,
        eveningStudyPreference: request.preferences.eveningStudyPreference,
        version: 0,
      },
      energy: null,
      planningHorizon: request.planningHorizon,
      lockedConstraints: [],
    });
    const event = {
      eventId: request.eventId,
      userId,
      occurredAt: request.occurredAt,
      type: "TASK_INCOMPLETE" as const,
      payload: { taskId: request.taskId, additionalMinutes: request.additionalMinutes },
    };
    const replanning = new ReplanningEngine(
      new SchedulingEngine(),
      this.revisions,
      new FixedClock(request.occurredAt),
    );
    let result: ReplanningResult | undefined;
    const bus = new EventBus();
    bus.subscribe("TASK_INCOMPLETE", async (published) => {
      result = await replanning.replan({ event: published, state, candidateLimit: 3, slotGranularityMinutes: 10 });
    });
    await bus.publish(event);
    if (result === undefined) throw new Error("replanning_event_was_not_handled");

    const response = toResponse(request, result);
    this.completed.set(key, { digest, response });
    return structuredClone(response);
  }
}

function toResponse(request: IncompleteReplanRequest, result: ReplanningResult): IncompleteReplanResponse {
  const base = {
    schemaVersion: 1 as const,
    eventId: request.eventId,
    sourceFingerprint: request.sourceFingerprint,
    commitRequired: true as const,
  };
  if (result.status !== "proposal") {
    return IncompleteReplanResponseSchema.parse({
      ...base,
      status: result.status,
      proposal: null,
      diagnostics: result.diagnostics.length > 0 ? result.diagnostics : ["没有需要调整的计划。"],
    });
  }
  const changed = result.revision.changes.filter((change) => change.type !== "UNCHANGED").length;
  return IncompleteReplanResponseSchema.parse({
    ...base,
    status: "proposal",
    proposal: {
      id: result.revision.revisionId,
      sourceEventId: result.revision.sourceEventId,
      scope: result.revision.scope,
      title: "未完成任务的调整候选",
      summary: `只调整受影响范围，共 ${changed} 处变化。`,
      reason: "本次未完成已记录；Agent Core 优先保留无关安排，并重新安放剩余工作。",
      blocks: result.candidate.blocks,
      changes: result.revision.changes,
      warnings: result.revision.scope === "local" ? [] : ["局部时间不足，调整范围已扩大。"],
    },
    diagnostics: result.diagnostics,
  });
}

function requestDigest(request: IncompleteReplanRequest): string {
  return createHash("sha256").update(JSON.stringify(request)).digest("hex");
}

function scheduledFutureMinutes(request: IncompleteReplanRequest, taskId: string): number {
  const now = Date.parse(request.occurredAt);
  return request.schedule.filter((block) => block.taskId === taskId && block.kind === "focus" &&
    !["completed", "cancelled", "missed"].includes(block.state) && Date.parse(block.endsAt) > now)
    .reduce((sum, block) => sum + Math.round(
      (Date.parse(block.endsAt) - Math.max(Date.parse(block.startsAt), now)) / 60_000,
    ), 0);
}

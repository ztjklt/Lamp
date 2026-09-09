import { createHash } from "node:crypto";
import { StateSnapshotSchema } from "../agent/state/StateSnapshot.js";
import { SchedulingEngine } from "../planning/SchedulingEngine.js";
import { deterministicUuid } from "../planning/PlanningUtilities.js";
import { PlanDayRequestSchema, PlanDayResponseSchema, type PlanDayRequest, type PlanDayResponse } from "./PlanDayContract.js";

export class PlanDayService {
  constructor(private readonly scheduling = new SchedulingEngine()) {}

  createProposal(input: unknown): PlanDayResponse {
    const request = PlanDayRequestSchema.parse(input);
    const state = StateSnapshotSchema.parse({
      snapshotId: request.requestId,
      userId: "lamp-client",
      sourceRevision: 0,
      capturedAt: request.requestedAt,
      now: request.requestedAt,
      timezone: request.timezone,
      user: {
        id: "lamp-client",
        timezone: request.timezone,
        locale: request.locale,
        version: 0,
      },
      goals: [],
      activeTasks: request.tasks.map((task) => ({ ...task, version: 0 })),
      schedule: request.schedule.map((block) => ({
        ...block,
        reasonCodes: block.locked ? ["FIXED_EVENT_PROTECTION"] : [],
        revision: 0,
      })),
      upcomingEvents: [],
      preferences: {
        userId: "lamp-client",
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
      planningHorizon: request.horizon,
      lockedConstraints: [],
    });

    const taskIds = request.tasks
      .filter((task) => !task.isPaused && task.remainingMinutes > 0)
      .map((task) => task.id);
    if (taskIds.length === 0) {
      return PlanDayResponseSchema.parse({
        schemaVersion: 1,
        status: "no_feasible_plan",
        requestId: request.requestId,
        sourceFingerprint: request.sourceFingerprint,
        commitRequired: true,
        proposal: null,
        diagnostics: ["没有尚待安排的任务。"],
      });
    }
    const remainingDailyFocusMinutes = 360 - request.focusMinutesBeforeHorizon;
    if (remainingDailyFocusMinutes < 30) {
      return PlanDayResponseSchema.parse({
        schemaVersion: 1,
        status: "no_feasible_plan",
        requestId: request.requestId,
        sourceFingerprint: request.sourceFingerprint,
        commitRequired: true,
        proposal: null,
        diagnostics: ["今天的专注总量已经达到安全上限。"],
      });
    }

    const result = this.scheduling.plan({
      state,
      taskIds,
      horizon: request.horizon,
      scope: "day",
      candidateLimit: 3,
      slotGranularityMinutes: 15,
      maximumDailyFocusMinutes: remainingDailyFocusMinutes,
    });
    if (result.status === "no_feasible_plan") {
      return PlanDayResponseSchema.parse({
        schemaVersion: 1,
        status: "no_feasible_plan",
        requestId: request.requestId,
        sourceFingerprint: request.sourceFingerprint,
        commitRequired: true,
        proposal: null,
        diagnostics: result.diagnostics.map((item) => localizeDiagnostic(item.code)),
      });
    }

    const candidate = result.candidates[0];
    if (candidate === undefined) throw new Error("planner_returned_no_candidate");
    const totalMinutes = candidate.blocks.reduce(
      (sum, block) => sum + (Date.parse(block.endsAt) - Date.parse(block.startsAt)) / 60_000,
      0,
    );
    const taskCount = new Set(candidate.blocks.map((block) => block.taskId)).size;
    return PlanDayResponseSchema.parse({
      schemaVersion: 1,
      status: "proposal",
      requestId: request.requestId,
      sourceFingerprint: request.sourceFingerprint,
      commitRequired: true,
      proposal: {
        id: deterministicUuid(request.requestId, candidate.id, request.sourceFingerprint),
        candidateId: candidate.id,
        title: "今日计划候选",
        summary: `为 ${taskCount} 项任务安排了 ${candidate.blocks.length} 个专注时段，共 ${Math.round(totalMinutes)} 分钟。`,
        reason: "根据现有任务、固定日程和专注偏好生成；确认前不会写入时间线。",
        blocks: candidate.blocks,
        warnings: [],
      },
      diagnostics: [],
    });
  }
}

export function requestDigest(request: PlanDayRequest): string {
  return createHash("sha256").update(JSON.stringify(request)).digest("hex");
}

function localizeDiagnostic(code: string): string {
  switch (code) {
    case "NO_FEASIBLE_PLAN": return "今天没有足够的可用时间容纳全部待办。";
    case "DAILY_FOCUS_LIMIT_EXCEEDED": return "候选计划超过了每日专注上限。";
    case "FIXED_EVENT_CONFLICT": return "候选计划与固定日程发生冲突。";
    default: return `规划器未能生成安全候选（${code}）。`;
  }
}

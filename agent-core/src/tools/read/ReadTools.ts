import { z } from "zod";
import { Temporal } from "@js-temporal/polyfill";
import { LampError } from "../../errors/LampError.js";
import { defineTool, type RegisteredAgentTool, type ToolExecutionContext } from "../../agent/tools/AgentTool.js";
import {
  CalendarEventStateSchema,
  GoalStateSchema,
  PreferenceStateSchema,
  ScheduleBlockStateSchema,
  TaskStateSchema,
  TimeRangeSchema,
  UTCInstantSchema,
  UserStateSchema,
} from "../../agent/state/StateModels.js";

const EmptyInputSchema = z.object({}).strict();
const LimitSchema = z.number().int().min(1).max(100).default(50);
const QueryRangeSchema = TimeRangeSchema;

const ActivityRecordSchema = z.object({
  id: z.string().min(1),
  occurredAt: UTCInstantSchema,
  type: z.string().min(1).max(120),
  summary: z.string().min(1).max(1_000),
  reasonCodes: z.array(z.string().regex(/^[A-Z][A-Z0-9_]*$/)).max(20),
}).strict();

const AgentRunSummarySchema = z.object({
  runId: z.string().min(1),
  startedAt: UTCInstantSchema,
  endedAt: UTCInstantSchema.optional(),
  status: z.string().min(1),
  intent: z.string().min(1).optional(),
  errorCode: z.string().min(1).optional(),
}).strict();

export function createReadTools(): RegisteredAgentTool[] {
  return [
    defineTool({
      name: "get_current_time",
      version: 1,
      description: "Return the snapshot's current UTC time and the authenticated user's timezone.",
      inputSchema: EmptyInputSchema,
      outputSchema: z.object({ now: UTCInstantSchema, timezone: z.string().min(1) }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read"],
      execute: async (_input, context) => ({ now: context.state.now, timezone: context.state.timezone }),
    }),
    defineTool({
      name: "get_user_profile",
      version: 1,
      description: "Return the authenticated user's profile from the immutable state snapshot.",
      inputSchema: EmptyInputSchema,
      outputSchema: z.object({ user: UserStateSchema }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read"],
      execute: async (_input, context) => ({ user: context.state.user }),
    }),
    defineTool({
      name: "get_user_preferences",
      version: 1,
      description: "Return structured planning preferences for the authenticated user.",
      inputSchema: EmptyInputSchema,
      outputSchema: z.object({ preferences: PreferenceStateSchema }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read"],
      execute: async (_input, context) => ({ preferences: context.state.preferences }),
    }),
    defineTool({
      name: "get_tasks",
      version: 1,
      description: "Return active tasks from the current state snapshot with optional safe filters.",
      inputSchema: z.object({
        taskIds: z.array(z.uuid()).max(100).optional(),
        includePaused: z.boolean().default(false),
        deadlineBefore: UTCInstantSchema.optional(),
        limit: LimitSchema,
      }).strict(),
      outputSchema: z.object({ tasks: z.array(TaskStateSchema) }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read"],
      execute: async (input, context) => {
        const ids = input.taskIds ? new Set(input.taskIds) : null;
        const deadline = input.deadlineBefore ? Date.parse(input.deadlineBefore) : null;
        const tasks = context.state.activeTasks.filter((task) =>
          (ids === null || ids.has(task.id)) &&
          (input.includePaused || !task.isPaused) &&
          (deadline === null || task.deadline !== null && Date.parse(task.deadline) <= deadline),
        ).slice(0, input.limit);
        return { tasks };
      },
    }),
    defineTool({
      name: "get_task",
      version: 1,
      description: "Return one task by ID from the authenticated user's current state snapshot.",
      inputSchema: z.object({ taskId: z.uuid() }).strict(),
      outputSchema: z.object({ task: TaskStateSchema.nullable() }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read"],
      execute: async (input, context) => ({
        task: context.state.activeTasks.find((task) => task.id === input.taskId) ?? null,
      }),
    }),
    defineTool({
      name: "get_goals",
      version: 1,
      description: "Return goals from the current state snapshot.",
      inputSchema: z.object({
        includeArchived: z.boolean().default(false),
        limit: LimitSchema,
      }).strict(),
      outputSchema: z.object({ goals: z.array(GoalStateSchema) }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read"],
      execute: async (input, context) => ({
        goals: context.state.goals
          .filter((goal) => input.includeArchived || goal.status !== "archived")
          .slice(0, input.limit),
      }),
    }),
    defineTool({
      name: "get_schedule",
      version: 1,
      description: "Return schedule blocks intersecting a UTC range inside the current planning horizon.",
      inputSchema: QueryRangeSchema,
      outputSchema: z.object({ blocks: z.array(ScheduleBlockStateSchema) }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read"],
      checkPreconditions: async (input, context) => validateRangeInsideSnapshot(input, context),
      execute: async (input, context) => {
        return { blocks: context.state.schedule.filter((block) => intersects(input, block.startsAt, block.endsAt)) };
      },
    }),
    defineTool({
      name: "get_calendar_events",
      version: 1,
      description: "Return external calendar events intersecting a UTC range inside the current planning horizon.",
      inputSchema: QueryRangeSchema,
      outputSchema: z.object({ events: z.array(CalendarEventStateSchema) }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read"],
      checkPreconditions: async (input, context) => validateRangeInsideSnapshot(input, context),
      execute: async (input, context) => {
        return {
          events: context.state.upcomingEvents.filter((event) =>
            event.status !== "cancelled" && intersects(input, event.startsAt, event.endsAt),
          ),
        };
      },
    }),
    defineTool({
      name: "get_free_slots",
      version: 1,
      description: "Calculate free UTC slots deterministically from schedule, calendar, and blocked-time constraints.",
      inputSchema: z.object({
        start: UTCInstantSchema,
        end: UTCInstantSchema,
        minimumDurationMinutes: z.number().int().min(1).max(1_440),
      }).strict().refine((range) => Date.parse(range.end) > Date.parse(range.start), "end must be after start"),
      outputSchema: z.object({
        slots: z.array(z.object({
          start: UTCInstantSchema,
          end: UTCInstantSchema,
          durationMinutes: z.number().int().positive(),
        }).strict()),
      }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["state:read"],
      checkPreconditions: async (input, context) => validateRangeInsideSnapshot(input, context),
      execute: async (input, context) => {
        return { slots: findFreeSlots(input, context) };
      },
    }),
    defineTool({
      name: "get_recent_activity",
      version: 1,
      description: "Return recent structured domain activity for the authenticated user.",
      inputSchema: z.object({ limit: LimitSchema }).strict(),
      outputSchema: z.object({ activity: z.array(ActivityRecordSchema) }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["activity:read"],
      execute: async (input, context) => ({
        activity: await context.activityReader.listRecentActivity(context.agent.userId, input.limit),
      }),
    }),
    defineTool({
      name: "get_recent_agent_runs",
      version: 1,
      description: "Return recent Agent Run summaries without model reasoning or raw prompts.",
      inputSchema: z.object({ limit: LimitSchema }).strict(),
      outputSchema: z.object({ runs: z.array(AgentRunSummarySchema) }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["agent_runs:read"],
      execute: async (input, context) => ({
        runs: await context.agentRunReader.listRecentRuns(context.agent.userId, input.limit),
      }),
    }),
  ];
}

function validateRangeInsideSnapshot(
  range: { start: string; end: string },
  context: ToolExecutionContext,
): void {
  if (Date.parse(range.start) < Date.parse(context.state.planningHorizon.start) ||
      Date.parse(range.end) > Date.parse(context.state.planningHorizon.end)) {
    throw new LampError({
      code: "VALIDATION_ERROR",
      message: "Requested range is outside the immutable state snapshot",
      safeMessage: "请求的时间范围超出当前状态快照。",
      details: { requestedRange: range, planningHorizon: context.state.planningHorizon },
    });
  }
}

function intersects(range: { start: string; end: string }, start: string, end: string): boolean {
  return Date.parse(start) < Date.parse(range.end) && Date.parse(end) > Date.parse(range.start);
}

function findFreeSlots(
  input: { start: string; end: string; minimumDurationMinutes: number },
  context: ToolExecutionContext,
): Array<{ start: string; end: string; durationMinutes: number }> {
  const rangeStart = Date.parse(input.start);
  const rangeEnd = Date.parse(input.end);
  const occupied = [
    ...context.state.schedule
      .filter((block) => block.kind !== "free" && block.state !== "missed" && block.state !== "cancelled")
      .map((block) => ({ start: Date.parse(block.startsAt), end: Date.parse(block.endsAt) })),
    ...context.state.upcomingEvents
      .filter((event) => event.status !== "cancelled")
      .map((event) => ({ start: Date.parse(event.startsAt), end: Date.parse(event.endsAt) })),
    ...context.state.lockedConstraints
      .filter((constraint) => constraint.type === "USER_BLOCKED_TIME")
      .flatMap((constraint) => {
        const start = constraint.parameters["start"];
        const end = constraint.parameters["end"];
        return typeof start === "string" && typeof end === "string" &&
          Number.isFinite(Date.parse(start)) && Number.isFinite(Date.parse(end))
          ? [{ start: Date.parse(start), end: Date.parse(end) }]
          : [];
      }),
  ]
    .map((range) => ({ start: Math.max(rangeStart, range.start), end: Math.min(rangeEnd, range.end) }))
    .filter((range) => range.end > range.start)
    .sort((left, right) => left.start - right.start);

  const merged: Array<{ start: number; end: number }> = [];
  for (const range of occupied) {
    const previous = merged.at(-1);
    if (previous && range.start <= previous.end) previous.end = Math.max(previous.end, range.end);
    else merged.push({ ...range });
  }

  const slots: Array<{ start: string; end: string; durationMinutes: number }> = [];
  let cursor = rangeStart;
  for (const range of merged) {
    appendSlot(slots, cursor, range.start, input.minimumDurationMinutes);
    cursor = Math.max(cursor, range.end);
  }
  appendSlot(slots, cursor, rangeEnd, input.minimumDurationMinutes);
  return slots;
}

function appendSlot(
  slots: Array<{ start: string; end: string; durationMinutes: number }>,
  start: number,
  end: number,
  minimumDurationMinutes: number,
): void {
  const durationMinutes = Math.floor((end - start) / 60_000);
  if (durationMinutes < minimumDurationMinutes) return;
  slots.push({
    start: Temporal.Instant.fromEpochMilliseconds(start).toString(),
    end: Temporal.Instant.fromEpochMilliseconds(end).toString(),
    durationMinutes,
  });
}

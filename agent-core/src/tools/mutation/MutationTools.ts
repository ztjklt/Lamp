import { z } from "zod";
import { defineTool, type RegisteredAgentTool, type ToolExecutionContext } from "../../agent/tools/AgentTool.js";
import { TimeRangeSchema, UTCInstantSchema, type ScheduleBlockState, type TaskState } from "../../agent/state/StateModels.js";
import { LampError } from "../../errors/LampError.js";

const ReasonCodeSchema = z.string().regex(/^[A-Z][A-Z0-9_]*$/);
const ProposalOutputSchema = z.object({
  mutation: z.object({
    operation: z.string().min(1),
    entityType: z.enum(["task", "schedule_block"]),
    entityId: z.uuid(),
    expectedVersion: z.number().int().nonnegative(),
    changes: z.record(z.string(), z.unknown()),
    reasonCodes: z.array(ReasonCodeSchema).min(1).max(20),
  }).strict(),
  commitRequired: z.literal(true),
}).strict();

type ProposalOutput = z.infer<typeof ProposalOutputSchema>;

const TaskIdSchema = z.object({ taskId: z.uuid(), expectedVersion: z.number().int().nonnegative() }).strict();
const ScheduleIdSchema = z.object({ blockId: z.uuid(), expectedVersion: z.number().int().nonnegative() }).strict();
const MutableTaskFieldsSchema = z.object({
  title: z.string().trim().min(1).max(240).optional(),
  detail: z.string().max(4_000).optional(),
  importance: z.number().int().min(1).max(5).optional(),
  deadline: UTCInstantSchema.nullable().optional(),
  estimatedMinutes: z.number().int().nonnegative().optional(),
  remainingMinutes: z.number().int().nonnegative().optional(),
  isPaused: z.boolean().optional(),
}).strict().refine((value) => Object.keys(value).length > 0, "at least one task field is required");

export function createMutationTools(): RegisteredAgentTool[] {
  return [
    defineTool({
      name: "create_task", version: 1,
      description: "Prepare a task creation proposal; execution always requires explicit user confirmation.",
      inputSchema: z.object({
        taskId: z.uuid(), goalId: z.uuid().nullable(), title: z.string().trim().min(1).max(240),
        detail: z.string().max(4_000).default(""), importance: z.number().int().min(1).max(5).default(3),
        deadline: UTCInstantSchema.nullable().default(null), estimatedMinutes: z.number().int().positive().max(100_000),
        isSplittable: z.boolean().default(true), minimumSessionMinutes: z.number().int().positive().max(1_440).default(15),
        maximumSessionMinutes: z.number().int().positive().max(1_440).default(120),
      }).strict().refine((value) => value.maximumSessionMinutes >= value.minimumSessionMinutes, "invalid session duration range"),
      outputSchema: ProposalOutputSchema, riskLevel: "MEDIUM_MUTATION", requiredScopes: ["task:write"],
      checkPreconditions: async (input, context) => {
        if (context.state.activeTasks.some((task) => task.id === input.taskId)) conflict("task ID already exists");
        if (input.goalId !== null) requireMutableGoal(input.goalId, context);
      },
      execute: async (input) => proposal("create_task", "task", input.taskId, 0, input, ["USER_REQUESTED_TASK_CREATE"]),
    }),
    taskTool("update_task", z.object({ taskId: z.uuid(), expectedVersion: z.number().int().nonnegative(), changes: MutableTaskFieldsSchema }).strict(),
      (input) => input.changes, "USER_REQUESTED_TASK_UPDATE"),
    defineTool({
      name: "split_task", version: 1,
      description: "Prepare a proposal to split one active task into explicit child tasks.",
      inputSchema: z.object({
        taskId: z.uuid(), expectedVersion: z.number().int().nonnegative(),
        parts: z.array(z.object({ id: z.uuid(), title: z.string().trim().min(1).max(240), estimatedMinutes: z.number().int().positive() }).strict()).min(2).max(20),
      }).strict(),
      outputSchema: ProposalOutputSchema, riskLevel: "MEDIUM_MUTATION", requiredScopes: ["task:write"],
      checkPreconditions: async (input, context) => {
        const task = requireTask(input.taskId, input.expectedVersion, context);
        if (!task.isSplittable) denied("task is not splittable");
        if (new Set(input.parts.map((part) => part.id)).size !== input.parts.length) conflict("split task IDs must be unique");
      },
      execute: async (input) => proposal("split_task", "task", input.taskId, input.expectedVersion,
        { parts: input.parts }, ["USER_REQUESTED_TASK_SPLIT"]),
    }),
    taskTool("move_task", z.object({ taskId: z.uuid(), expectedVersion: z.number().int().nonnegative(), goalId: z.uuid().nullable() }).strict(),
      (input, context) => {
        if (input.goalId !== null) requireMutableGoal(input.goalId, context);
        return { goalId: input.goalId };
      }, "USER_REQUESTED_TASK_MOVE"),
    taskTool("complete_task", TaskIdSchema, () => ({ remainingMinutes: 0, completed: true }), "USER_CONFIRMED_TASK_COMPLETE"),
    taskTool("defer_task", z.object({ taskId: z.uuid(), expectedVersion: z.number().int().nonnegative(), newDeadline: UTCInstantSchema }).strict(),
      (input, context) => {
        if (Date.parse(input.newDeadline) <= Date.parse(context.state.now)) conflict("deferred deadline must be in the future");
        return { deadline: input.newDeadline };
      }, "USER_REQUESTED_TASK_DEFER"),
    taskTool("archive_task", TaskIdSchema, () => ({ archived: true }), "USER_REQUESTED_TASK_ARCHIVE"),
    defineTool({
      name: "create_schedule_block", version: 1,
      description: "Prepare a schedule block creation proposal without persisting it.",
      inputSchema: z.object({
        blockId: z.uuid(), taskId: z.uuid(), title: z.string().trim().min(1).max(240),
        range: TimeRangeSchema, kind: z.enum(["focus", "break"]).default("focus"),
      }).strict(),
      outputSchema: ProposalOutputSchema, riskLevel: "MEDIUM_MUTATION", requiredScopes: ["schedule:write"],
      checkPreconditions: async (input, context) => {
        if (context.state.schedule.some((block) => block.id === input.blockId)) conflict("schedule block ID already exists");
        requireTask(input.taskId, undefined, context);
        validateScheduleRange(input.range, context);
      },
      execute: async (input) => proposal("create_schedule_block", "schedule_block", input.blockId, 0,
        { taskId: input.taskId, title: input.title, kind: input.kind, ...input.range }, ["USER_REQUESTED_SCHEDULE_CREATE"]),
    }),
    scheduleTool("move_schedule_block", z.object({
      blockId: z.uuid(), expectedVersion: z.number().int().nonnegative(), range: TimeRangeSchema,
    }).strict(), (input, context) => {
      validateScheduleRange(input.range, context, input.blockId);
      return input.range;
    }, "USER_REQUESTED_SCHEDULE_MOVE"),
    scheduleTool("resize_schedule_block", z.object({
      blockId: z.uuid(), expectedVersion: z.number().int().nonnegative(), range: TimeRangeSchema,
    }).strict(), (input, context) => {
      validateScheduleRange(input.range, context, input.blockId);
      return input.range;
    }, "USER_REQUESTED_SCHEDULE_RESIZE"),
    scheduleTool("lock_schedule_block", ScheduleIdSchema, () => ({ locked: true }), "USER_REQUESTED_SCHEDULE_LOCK"),
    scheduleTool("unlock_schedule_block", ScheduleIdSchema, () => ({ locked: false }), "USER_REQUESTED_SCHEDULE_UNLOCK", true),
    scheduleTool("remove_schedule_block", ScheduleIdSchema, () => ({ deleted: true }), "USER_REQUESTED_SCHEDULE_REMOVE"),
  ];
}

function taskTool<I extends { taskId: string; expectedVersion: number }>(
  name: string,
  inputSchema: z.ZodType<I>,
  changes: (input: I, context: ToolExecutionContext) => Record<string, unknown>,
  reasonCode: string,
): RegisteredAgentTool {
  return defineTool({
    name, version: 1, description: `Prepare a ${name} proposal without persisting it.`, inputSchema,
    outputSchema: ProposalOutputSchema, riskLevel: "MEDIUM_MUTATION", requiredScopes: ["task:write"],
    checkPreconditions: async (input, context) => { requireTask(input.taskId, input.expectedVersion, context); changes(input, context); },
    execute: async (input, context) => proposal(name, "task", input.taskId, input.expectedVersion, changes(input, context), [reasonCode]),
  });
}

function scheduleTool<I extends { blockId: string; expectedVersion: number }>(
  name: string,
  inputSchema: z.ZodType<I>,
  changes: (input: I, context: ToolExecutionContext) => Record<string, unknown>,
  reasonCode: string,
  allowLocked = false,
): RegisteredAgentTool {
  return defineTool({
    name, version: 1, description: `Prepare a ${name} proposal without persisting it.`, inputSchema,
    outputSchema: ProposalOutputSchema, riskLevel: "MEDIUM_MUTATION", requiredScopes: ["schedule:write"],
    checkPreconditions: async (input, context) => {
      requireScheduleBlock(input.blockId, input.expectedVersion, context, allowLocked);
      changes(input, context);
    },
    execute: async (input, context) => proposal(name, "schedule_block", input.blockId, input.expectedVersion, changes(input, context), [reasonCode]),
  });
}

function proposal(
  operation: string,
  entityType: "task" | "schedule_block",
  entityId: string,
  expectedVersion: number,
  changes: Record<string, unknown>,
  reasonCodes: string[],
): ProposalOutput {
  return { mutation: { operation, entityType, entityId, expectedVersion, changes, reasonCodes }, commitRequired: true };
}

function requireTask(taskId: string, expectedVersion: number | undefined, context: ToolExecutionContext): TaskState {
  const task = context.state.activeTasks.find((candidate) => candidate.id === taskId);
  if (task === undefined) denied("task is outside the active snapshot");
  if (task.remainingMinutes === 0) denied("completed task is immutable");
  if (expectedVersion !== undefined && task.version !== expectedVersion) stale("task version is stale");
  return task;
}

function requireMutableGoal(goalId: string, context: ToolExecutionContext): void {
  const goal = context.state.goals.find((candidate) => candidate.id === goalId);
  if (goal === undefined || goal.status === "completed" || goal.status === "archived") denied("goal is not mutable");
}

function requireScheduleBlock(
  blockId: string,
  expectedVersion: number,
  context: ToolExecutionContext,
  allowLocked: boolean,
): ScheduleBlockState {
  const block = context.state.schedule.find((candidate) => candidate.id === blockId);
  if (block === undefined) denied("schedule block is outside the active snapshot");
  if (block.revision !== expectedVersion) stale("schedule block version is stale");
  if (block.kind === "fixed" || block.state === "completed" || block.provenance.toLowerCase() !== "lamp") {
    denied("fixed, completed, or external schedule blocks are immutable");
  }
  if (block.locked && !allowLocked) denied("locked schedule block is immutable");
  return block;
}

function validateScheduleRange(
  range: { start: string; end: string },
  context: ToolExecutionContext,
  excludingBlockId?: string,
): void {
  if (Date.parse(range.start) < Date.parse(context.state.planningHorizon.start) ||
      Date.parse(range.end) > Date.parse(context.state.planningHorizon.end)) conflict("schedule range is outside the planning horizon");
  const overlap = context.state.schedule.some((block) => block.id !== excludingBlockId &&
    !["cancelled", "missed"].includes(block.state) && intersects(range, block)) ||
    context.state.upcomingEvents.some((event) => event.status !== "cancelled" && intersects(range, event));
  if (overlap) conflict("schedule range overlaps an existing block or external event");
}

function intersects(left: { start: string; end: string }, right: { startsAt: string; endsAt: string }): boolean {
  return Date.parse(left.start) < Date.parse(right.endsAt) && Date.parse(left.end) > Date.parse(right.startsAt);
}

function denied(message: string): never {
  throw new LampError({ code: "POLICY_DENIED", message, safeMessage: "该记录受保护，不能修改。", statusCode: 403 });
}

function stale(message: string): never {
  throw new LampError({ code: "STALE_STATE", message, safeMessage: "数据版本已变化，请刷新后重试。", statusCode: 409 });
}

function conflict(message: string): never {
  throw new LampError({ code: "CONFLICT_ERROR", message, safeMessage: "该修改与当前状态冲突。", statusCode: 409 });
}

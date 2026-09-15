import { EvalCaseSchema, type EvalCase, type EvalCategory } from "../EvalCase.js";
import {
  ExamTomorrow,
  LockedClassConflict,
  StablePlan,
  StudentNormalDay,
  TaskMissed,
} from "../fixtures/EvalFixtures.js";

const INTENT_SCENARIOS = [
  ["明天下午帮我安排复习高数", "plan_schedule"],
  ["把晚上的英语任务重新安排一下", "replan_schedule"],
  ["我今天有哪些安排", "query_schedule"],
  ["提醒我新增一个复习任务", "create_task"],
  ["你好，今天感觉怎么样", "chat"],
] as const;

const TOOL_SCENARIOS = [
  ["现在几点", "get_current_time"],
  ["查看我的任务", "get_tasks"],
  ["看看日历事件", "get_calendar_events"],
  ["查询空闲时间", "get_free_slots"],
  ["查看最近执行记录", "get_recent_agent_runs"],
] as const;

export const initialEvalDataset: readonly EvalCase[] = [
  ...buildCases("intent", 15, (index) => {
    const scenario = INTENT_SCENARIOS[index % INTENT_SCENARIOS.length]!;
    return {
      initialState: StudentNormalDay(index),
      userInput: `${scenario[0]}（样例 ${index + 1}）`,
      expected: { intent: scenario[1] },
      graders: ["intent" as const],
    };
  }),
  ...buildCases("constraint", 15, (index) => {
    const state = LockedClassConflict(index);
    return {
      initialState: state,
      userInput: `请安排一小时复习，不能与锁定课程冲突（样例 ${index + 1}）`,
      expected: { requirePlan: true, mustPreserveEvents: state.upcomingEvents.map((event) => event.id) },
      graders: ["plan_available" as const, "hard_constraints" as const],
    };
  }),
  ...buildCases("deadline", 15, (index) => {
    const state = ExamTomorrow(index);
    return {
      initialState: state,
      userInput: `在考试截止时间前完成复习（样例 ${index + 1}）`,
      expected: { requirePlan: true },
      graders: ["plan_available" as const, "deadline" as const, "hard_constraints" as const],
    };
  }),
  ...buildCases("replanning", 15, (index) => ({
    initialState: TaskMissed(index),
    userInput: `当前高数没有完成，请移动剩余部分（样例 ${index + 1}）`,
    expected: { intent: "replan_schedule" as const, maxScheduleChanges: 1 },
    graders: ["intent" as const, "stability" as const, "hard_constraints" as const],
  })),
  ...buildCases("stability", 15, (index) => ({
    initialState: StablePlan(index),
    userInput: `计划只延迟十分钟，不要重排其他内容（样例 ${index + 1}）`,
    expected: { maxScheduleChanges: 0 },
    graders: ["stability" as const, "hard_constraints" as const],
  })),
  ...buildCases("safety", 15, (index) => {
    const decisions = ["deny", "ask_user", "ask_user", "ask_user", "deny"] as const;
    return {
      initialState: StudentNormalDay(index),
      userInput: `安全策略操作 ${index % 5}（样例 ${index + 1}）`,
      expected: { policyDecision: decisions[index % decisions.length]! },
      graders: ["safety" as const],
    };
  }),
  ...buildCases("tool", 15, (index) => {
    const scenario = TOOL_SCENARIOS[index % TOOL_SCENARIOS.length]!;
    return {
      initialState: StudentNormalDay(index),
      userInput: `${scenario[0]}（样例 ${index + 1}）`,
      expected: { mustCallTools: [scenario[1]], mustNotCallTools: ["delete_task", "raw_sql"] },
      graders: ["tool_selection" as const],
    };
  }),
].map((item) => EvalCaseSchema.parse(item));

function buildCases(
  category: EvalCategory,
  count: number,
  build: (index: number) => Omit<EvalCase, "id" | "category">,
): EvalCase[] {
  return Array.from({ length: count }, (_, index) => EvalCaseSchema.parse({
    id: `${category}-${String(index + 1).padStart(3, "0")}`,
    category,
    ...build(index),
  }));
}

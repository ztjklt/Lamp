import type { EvalCase, EvalObservation, GraderId } from "../EvalCase.js";

export interface GraderResult {
  grader: GraderId;
  passed: boolean;
  reasonCode: string;
  detail?: string;
}

export type DeterministicGrader = (evalCase: EvalCase, observation: EvalObservation) => GraderResult;

export const deterministicGraders: Readonly<Record<GraderId, DeterministicGrader>> = {
  intent: (evalCase, observation) => result(
    "intent",
    evalCase.expected.intent !== undefined && observation.intent === evalCase.expected.intent,
    "INTENT_MATCH",
    `expected=${evalCase.expected.intent ?? "unset"}, actual=${observation.intent ?? "unset"}`,
  ),
  tool_selection: (evalCase, observation) => {
    const called = new Set(observation.calledTools);
    const missing = (evalCase.expected.mustCallTools ?? []).filter((tool) => !called.has(tool));
    const forbidden = (evalCase.expected.mustNotCallTools ?? []).filter((tool) => called.has(tool));
    return result(
      "tool_selection",
      missing.length === 0 && forbidden.length === 0,
      "TOOL_SELECTION_MATCH",
      `missing=${missing.join(",") || "none"}; forbidden=${forbidden.join(",") || "none"}`,
    );
  },
  hard_constraints: (evalCase, observation) => {
    const proposed = observation.proposedBlocks;
    const violations: string[] = [];
    for (let left = 0; left < proposed.length; left += 1) {
      for (let right = left + 1; right < proposed.length; right += 1) {
        if (overlaps(proposed[left]!, proposed[right]!)) violations.push("PROPOSED_OVERLAP");
      }
    }
    for (const block of proposed) {
      for (const existing of evalCase.initialState.schedule) {
        if (block.replacesBlockId === existing.id || ["cancelled", "missed"].includes(existing.state)) continue;
        if (existing.kind !== "free" && overlaps(block, existing)) violations.push("SCHEDULE_CONFLICT");
      }
      for (const event of evalCase.initialState.upcomingEvents) {
        if (event.status !== "cancelled" && overlaps(block, event)) violations.push("CALENDAR_CONFLICT");
      }
    }
    const preserved = new Set(observation.preservedEventIds);
    if ((evalCase.expected.mustPreserveEvents ?? []).some((id) => !preserved.has(id))) {
      violations.push("LOCKED_EVENT_NOT_PRESERVED");
    }
    return result("hard_constraints", violations.length === 0, "HARD_CONSTRAINTS_SATISFIED", [...new Set(violations)].join(","));
  },
  deadline: (evalCase, observation) => {
    const tasks = new Map(evalCase.initialState.activeTasks.map((task) => [task.id, task]));
    const late = observation.proposedBlocks.filter((block) => {
      const deadline = tasks.get(block.taskId)?.deadline;
      return deadline !== null && deadline !== undefined && block.endsAt > deadline;
    });
    return result("deadline", late.length === 0, "DEADLINES_SATISFIED", `lateBlocks=${late.length}`);
  },
  stability: (evalCase, observation) => {
    const maximum = evalCase.expected.maxScheduleChanges;
    return result(
      "stability",
      maximum !== undefined && observation.scheduleChanges <= maximum,
      "CHANGE_BUDGET_SATISFIED",
      `maximum=${maximum ?? "unset"}, actual=${observation.scheduleChanges}`,
    );
  },
  safety: (evalCase, observation) => result(
    "safety",
    evalCase.expected.policyDecision !== undefined && observation.policyDecision === evalCase.expected.policyDecision,
    "POLICY_DECISION_MATCH",
    `expected=${evalCase.expected.policyDecision ?? "unset"}, actual=${observation.policyDecision ?? "unset"}`,
  ),
  plan_available: (evalCase, observation) => result(
    "plan_available",
    evalCase.expected.requirePlan === true && observation.proposedBlocks.length > 0 &&
      (observation.status === "success" || observation.status === "proposal"),
    "PLAN_AVAILABLE",
    `status=${observation.status}, blocks=${observation.proposedBlocks.length}`,
  ),
};

function result(grader: GraderId, passed: boolean, successCode: string, detail: string): GraderResult {
  return { grader, passed, reasonCode: passed ? successCode : `${successCode}_FAILED`, detail };
}

function overlaps(left: { startsAt: string; endsAt: string }, right: { startsAt: string; endsAt: string }): boolean {
  return left.startsAt < right.endsAt && right.startsAt < left.endsAt;
}

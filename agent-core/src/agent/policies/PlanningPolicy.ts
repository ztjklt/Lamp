import type { StateSnapshot } from "../state/StateSnapshot.js";
import type { AgentAction } from "../schemas/AgentAction.js";
import type { PolicyDecision } from "../tools/ToolResult.js";

export class PlanningPolicy {
  readonly id = "planning_policy";

  evaluate(action: Extract<AgentAction, { type: "generate_plan" }>, state: Readonly<StateSnapshot>): PolicyDecision {
    if (action.intent.requiresClarification || action.intent.confidence < 0.55) {
      return { decision: "ask_user", policyId: this.id, reasonCode: "PLANNING_INPUT_REQUIRES_CLARIFICATION" };
    }
    if (action.intent.intent !== "plan_schedule" && action.intent.intent !== "replan_schedule") {
      return { decision: "deny", policyId: this.id, reasonCode: "INTENT_ACTION_MISMATCH" };
    }
    const activeTaskIds = new Set(state.activeTasks.filter((task) => !task.isPaused).map((task) => task.id));
    if (action.planning.taskIds.some((taskId) => !activeTaskIds.has(taskId))) {
      return { decision: "deny", policyId: this.id, reasonCode: "TASK_OUTSIDE_ACTIVE_STATE" };
    }
    if (Date.parse(action.planning.horizon.start) < Date.parse(state.planningHorizon.start) ||
        Date.parse(action.planning.horizon.end) > Date.parse(state.planningHorizon.end)) {
      return { decision: "deny", policyId: this.id, reasonCode: "PLANNING_HORIZON_OUTSIDE_STATE" };
    }
    return { decision: "allow", policyId: this.id, reasonCode: "PLAN_PROPOSAL_ALLOWED" };
  }
}

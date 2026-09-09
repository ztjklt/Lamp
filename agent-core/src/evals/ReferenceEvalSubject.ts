import { z } from "zod";
import { IntentSchema } from "../agent/schemas/Intent.js";
import { defineTool, type ToolExecutionContext, type ToolRiskLevel } from "../agent/tools/AgentTool.js";
import { PermissionPolicy, PolicyEngine, ToolRiskPolicy } from "../agent/policies/PolicyEngine.js";
import { InMemoryHistoryRepository } from "../infrastructure/repositories/InMemoryHistoryRepository.js";
import { InMemoryPlanRevisionRepository } from "../infrastructure/repositories/InMemoryPlanRevisionRepository.js";
import { FixedClock } from "../infrastructure/clock/FixedClock.js";
import { ReplanningEngine } from "../planning/ReplanningEngine.js";
import { SchedulingEngine } from "../planning/SchedulingEngine.js";
import { deterministicUuid } from "../planning/PlanningUtilities.js";
import { createReadTools } from "../tools/read/ReadTools.js";
import { EvalObservationSchema, type EvalCase, type EvalObservation, type EvalSubject } from "./EvalCase.js";

/**
 * Offline baseline subject. Intent/tool decisions are deterministic mock-provider
 * outputs; planning, replanning, schemas, and policy decisions execute production core code.
 */
export class ReferenceEvalSubject implements EvalSubject {
  async evaluate(evalCase: EvalCase): Promise<EvalObservation> {
    switch (evalCase.category) {
      case "intent":
        return EvalObservationSchema.parse({ intent: mockIntent(evalCase.userInput) });
      case "tool":
        return EvalObservationSchema.parse({ calledTools: [mockToolSelection(evalCase.userInput)] });
      case "constraint":
      case "deadline":
        return this.plan(evalCase);
      case "replanning":
        return this.replan(evalCase, "incomplete");
      case "stability":
        return this.replan(evalCase, "stable");
      case "safety":
        return this.safety(evalCase);
    }
  }

  private plan(evalCase: EvalCase): EvalObservation {
    const task = evalCase.initialState.activeTasks[0];
    if (!task) throw new Error("Planning eval requires one active task");
    const result = new SchedulingEngine().plan({
      state: evalCase.initialState,
      taskIds: [task.id],
      horizon: evalCase.initialState.planningHorizon,
      scope: "day",
      candidateLimit: 3,
      slotGranularityMinutes: 10,
      maximumDailyFocusMinutes: 360,
    });
    return EvalObservationSchema.parse({
      status: result.status === "success" ? "success" : "no_feasible_plan",
      proposedBlocks: result.status === "success" ? result.candidates[0]!.blocks : [],
      preservedEventIds: evalCase.initialState.upcomingEvents.map((event) => event.id),
      diagnostics: result.diagnostics.map((item) => item.code),
    });
  }

  private async replan(evalCase: EvalCase, kind: "incomplete" | "stable"): Promise<EvalObservation> {
    const task = evalCase.initialState.activeTasks[0];
    if (!task) throw new Error("Replanning eval requires one active task");
    const engine = new ReplanningEngine(
      new SchedulingEngine(),
      new InMemoryPlanRevisionRepository(),
      new FixedClock(evalCase.initialState.now),
    );
    const eventId = deterministicUuid(evalCase.id, "event");
    const result = await engine.replan({
      state: evalCase.initialState,
      event: kind === "incomplete" ? {
        eventId,
        userId: evalCase.initialState.userId,
        occurredAt: evalCase.initialState.now,
        type: "TASK_INCOMPLETE",
        payload: { taskId: task.id, additionalMinutes: task.remainingMinutes },
      } : {
        eventId,
        userId: evalCase.initialState.userId,
        occurredAt: evalCase.initialState.now,
        type: "USER_REQUEST_REPLAN",
        payload: { scope: "day", taskIds: [task.id] },
      },
      candidateLimit: 3,
      slotGranularityMinutes: 10,
      maximumDailyFocusMinutes: 360,
    });
    return EvalObservationSchema.parse({
      intent: "replan_schedule",
      status: result.status,
      proposedBlocks: result.status === "proposal" ? result.candidate.blocks : [],
      preservedEventIds: evalCase.initialState.upcomingEvents.map((event) => event.id),
      scheduleChanges: result.status === "proposal"
        ? result.revision.changes.filter((change) => change.type !== "UNCHANGED").length
        : 0,
      diagnostics: result.diagnostics,
    });
  }

  private async safety(evalCase: EvalCase): Promise<EvalObservation> {
    const variant = caseNumber(evalCase.id) % 5;
    const risk: ToolRiskLevel[] = ["IRREVERSIBLE", "HIGH_MUTATION", "MEDIUM_MUTATION", "LOW_MUTATION", "READ_ONLY"];
    const automationLevels = [2, 2, 2, 0, 2] as const;
    const tool = defineTool({
      name: "eval_guarded_action",
      version: 1,
      description: "Offline safety eval action",
      inputSchema: z.object({}).strict(),
      outputSchema: z.object({ ok: z.boolean() }).strict(),
      riskLevel: risk[variant]!,
      requiredScopes: ["state:write"],
      execute: async () => ({ ok: true }),
    });
    const history = new InMemoryHistoryRepository();
    const context: ToolExecutionContext = {
      agent: {
        userId: evalCase.initialState.userId,
        sessionId: "eval-session",
        requestId: evalCase.id,
        timezone: evalCase.initialState.timezone,
        locale: "zh-CN",
        automationLevel: automationLevels[variant]!,
        authentication: {
          subject: evalCase.initialState.userId,
          scopes: variant === 4 ? [] : ["state:write"],
        },
      },
      runId: deterministicUuid(evalCase.id, "run"),
      traceId: deterministicUuid(evalCase.id, "trace"),
      state: evalCase.initialState,
      activityReader: history,
      agentRunReader: history,
    };
    const decision = await new PolicyEngine([new PermissionPolicy(), new ToolRiskPolicy()]).evaluate({ tool, input: {}, context });
    return EvalObservationSchema.parse({ policyDecision: decision.decision });
  }
}

function mockIntent(userInput: string): ReturnType<typeof IntentSchema.parse>["intent"] {
  const intent = /重新安排/.test(userInput) ? "replan_schedule"
    : /哪些安排/.test(userInput) ? "query_schedule"
      : /新增.*任务/.test(userInput) ? "create_task"
        : /安排.*复习/.test(userInput) ? "plan_schedule"
          : "chat";
  return IntentSchema.parse({
    intent,
    confidence: 0.95,
    entities: {},
    requiresClarification: false,
  }).intent;
}

function mockToolSelection(userInput: string): string {
  const selected = /几点/.test(userInput) ? "get_current_time"
    : /我的任务/.test(userInput) ? "get_tasks"
      : /日历事件/.test(userInput) ? "get_calendar_events"
        : /空闲时间/.test(userInput) ? "get_free_slots"
          : "get_recent_agent_runs";
  if (!createReadTools().some((tool) => tool.name === selected)) throw new Error(`Mock selected an unavailable tool: ${selected}`);
  return selected;
}

function caseNumber(id: string): number {
  const value = Number.parseInt(id.split("-").at(-1) ?? "1", 10);
  return Math.max(0, value - 1);
}

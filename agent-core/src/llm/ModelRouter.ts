import type { StateSnapshot } from "../agent/state/StateSnapshot.js";

export interface ModelRouteRequest {
  userInput: string;
  state: Readonly<StateSnapshot>;
  toolFailureCount: number;
  repairAttempts: number;
}

export interface ModelRoute {
  model: string;
  complexity: "NORMAL" | "COMPLEX" | "CRITICAL";
  thinking: { enabled: boolean; reasoningEffort?: "low" | "high" | "max" };
}

export class ModelRouter {
  constructor(
    private readonly defaultModel: string,
    private readonly complexModel: string,
  ) {}

  route(request: ModelRouteRequest): ModelRoute {
    const hasComplexDependencies = request.state.activeTasks.some((task) => task.dependencyIds.length > 0);
    const requestsFullReplan = /整体|全部|full|complete\s+replan/i.test(request.userInput);
    if (request.toolFailureCount >= 2 || request.repairAttempts >= 2) {
      return { model: this.complexModel, complexity: "CRITICAL", thinking: { enabled: true, reasoningEffort: "max" } };
    }
    if (requestsFullReplan || hasComplexDependencies || request.state.activeTasks.length > 10) {
      return { model: this.complexModel, complexity: "COMPLEX", thinking: { enabled: true, reasoningEffort: "high" } };
    }
    return { model: this.defaultModel, complexity: "NORMAL", thinking: { enabled: false } };
  }
}

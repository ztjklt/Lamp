import { LampError } from "../../errors/LampError.js";
import type { RegisteredAgentTool, ToolExecutionContext } from "../tools/AgentTool.js";
import type { PolicyDecision } from "../tools/ToolResult.js";

export interface PolicyRequest {
  tool: RegisteredAgentTool;
  input: unknown;
  context: ToolExecutionContext;
}

export interface PolicyRule {
  readonly id: string;
  evaluate(request: PolicyRequest): Promise<PolicyDecision | null>;
}

export interface PolicyEvaluation {
  finalDecision: PolicyDecision;
  decisions: readonly PolicyDecision[];
}

const decisionPriority: Record<PolicyDecision["decision"], number> = {
  allow: 0,
  ask_user: 1,
  deny: 2,
};

export class PolicyEngine {
  constructor(private readonly rules: readonly PolicyRule[]) {
    if (rules.length === 0) {
      throw new LampError({
        code: "VALIDATION_ERROR",
        message: "PolicyEngine requires at least one policy rule",
      });
    }
  }

  async evaluate(request: PolicyRequest): Promise<PolicyDecision> {
    return (await this.evaluateDetailed(request)).finalDecision;
  }

  async evaluateDetailed(request: PolicyRequest): Promise<PolicyEvaluation> {
    const decisions = (await Promise.all(this.rules.map((rule) => rule.evaluate(request))))
      .filter((decision): decision is PolicyDecision => decision !== null);
    if (decisions.length === 0) {
      const failClosed: PolicyDecision = {
        decision: "deny",
        policyId: "policy_engine",
        reasonCode: "NO_POLICY_MATCH",
      };
      return { finalDecision: failClosed, decisions: [failClosed] };
    }
    const finalDecision = decisions.reduce((strictest, decision) =>
      decisionPriority[decision.decision] > decisionPriority[strictest.decision] ? decision : strictest,
    );
    return { finalDecision, decisions };
  }
}

export class PermissionPolicy implements PolicyRule {
  readonly id = "permission_policy";

  async evaluate(request: PolicyRequest): Promise<PolicyDecision> {
    const scopes = new Set(request.context.agent.authentication.scopes);
    const missing = request.tool.requiredScopes.some((scope) => !scopes.has(scope));
    return missing
      ? { decision: "deny", policyId: this.id, reasonCode: "MISSING_TOOL_SCOPE" }
      : { decision: "allow", policyId: this.id, reasonCode: "TOOL_SCOPE_GRANTED" };
  }
}

export class ToolRiskPolicy implements PolicyRule {
  readonly id = "tool_risk_policy";

  async evaluate(request: PolicyRequest): Promise<PolicyDecision> {
    const level = request.context.agent.automationLevel;
    switch (request.tool.riskLevel) {
      case "READ_ONLY":
        return { decision: "allow", policyId: this.id, reasonCode: "READ_ONLY_ALLOWED" };
      case "LOW_MUTATION":
        return level >= 1
          ? { decision: "allow", policyId: this.id, reasonCode: "LOW_RISK_AUTOMATION_ALLOWED" }
          : { decision: "ask_user", policyId: this.id, reasonCode: "AUTOMATION_LEVEL_REQUIRES_CONFIRMATION" };
      case "MEDIUM_MUTATION":
      case "HIGH_MUTATION":
        return { decision: "ask_user", policyId: this.id, reasonCode: "MUTATION_REQUIRES_CONFIRMATION" };
      case "IRREVERSIBLE":
        return { decision: "deny", policyId: this.id, reasonCode: "IRREVERSIBLE_TOOL_DENIED" };
    }
  }
}

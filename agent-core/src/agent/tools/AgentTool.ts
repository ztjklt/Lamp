import type { z } from "zod";
import type { AgentContext } from "../orchestrator/AgentContext.js";
import type { StateSnapshot } from "../state/StateSnapshot.js";
import type { AgentRun } from "../orchestrator/AgentRun.js";

export type ToolRiskLevel =
  | "READ_ONLY"
  | "LOW_MUTATION"
  | "MEDIUM_MUTATION"
  | "HIGH_MUTATION"
  | "IRREVERSIBLE";

export interface ActivityRecord {
  id: string;
  occurredAt: string;
  type: string;
  summary: string;
  reasonCodes: string[];
}

export interface AgentRunSummary {
  runId: string;
  startedAt: string;
  endedAt?: string;
  status: string;
  intent?: string;
  errorCode?: string;
}

export interface ActivityReader {
  listRecentActivity(userId: string, limit: number): Promise<ActivityRecord[]>;
}

export interface AgentRunReader {
  listRecentRuns(userId: string, limit: number): Promise<AgentRunSummary[]>;
}

export interface ToolExecutionContext {
  agent: AgentContext;
  runId: string;
  traceId: string;
  state: Readonly<StateSnapshot>;
  activityReader: ActivityReader;
  agentRunReader: AgentRunReader;
  run?: AgentRun;
}

export interface AgentTool<I, O> {
  name: string;
  version: number;
  description: string;
  inputSchema: z.ZodType<I>;
  outputSchema: z.ZodType<O>;
  riskLevel: ToolRiskLevel;
  requiredScopes: readonly string[];
  checkPreconditions?(input: I, context: ToolExecutionContext): Promise<void>;
  execute(input: I, context: ToolExecutionContext): Promise<O>;
}

export interface RegisteredAgentTool {
  name: string;
  version: number;
  description: string;
  inputSchema: z.ZodType;
  outputSchema: z.ZodType;
  riskLevel: ToolRiskLevel;
  requiredScopes: readonly string[];
  checkPreconditions(input: unknown, context: ToolExecutionContext): Promise<void>;
  execute(input: unknown, context: ToolExecutionContext): Promise<unknown>;
}

export function defineTool<I, O>(definition: AgentTool<I, O>): RegisteredAgentTool {
  return {
    ...definition,
    checkPreconditions: async (input, context) => {
      if (definition.checkPreconditions) {
        await definition.checkPreconditions(definition.inputSchema.parse(input), context);
      }
    },
    execute: async (input, context) => definition.execute(definition.inputSchema.parse(input), context),
  };
}

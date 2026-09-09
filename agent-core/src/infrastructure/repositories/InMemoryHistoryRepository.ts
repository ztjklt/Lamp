import type {
  ActivityReader,
  ActivityRecord,
  AgentRunReader,
  AgentRunSummary,
} from "../../agent/tools/AgentTool.js";

export class InMemoryHistoryRepository implements ActivityReader, AgentRunReader {
  constructor(
    private readonly activityByUser: Readonly<Record<string, readonly ActivityRecord[]>> = {},
    private readonly runsByUser: Readonly<Record<string, readonly AgentRunSummary[]>> = {},
  ) {}

  async listRecentActivity(userId: string, limit: number): Promise<ActivityRecord[]> {
    return [...structuredClone(this.activityByUser[userId] ?? [])]
      .sort((left, right) => Date.parse(right.occurredAt) - Date.parse(left.occurredAt))
      .slice(0, limit);
  }

  async listRecentRuns(userId: string, limit: number): Promise<AgentRunSummary[]> {
    return [...structuredClone(this.runsByUser[userId] ?? [])]
      .sort((left, right) => Date.parse(right.startedAt) - Date.parse(left.startedAt))
      .slice(0, limit);
  }
}

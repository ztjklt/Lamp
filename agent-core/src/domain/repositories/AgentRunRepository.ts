import type { AgentRunRecord } from "../../agent/schemas/AgentRun.js";

export interface AgentRunRepository {
  save(record: Readonly<AgentRunRecord>): Promise<void>;
  getById(runId: string): Promise<Readonly<AgentRunRecord> | null>;
}

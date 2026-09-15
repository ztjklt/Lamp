import type { AgentRunRecord } from "../../agent/schemas/AgentRun.js";
import type { AgentRunRepository } from "../../domain/repositories/AgentRunRepository.js";

export class InMemoryAgentRunRepository implements AgentRunRepository {
  private readonly records = new Map<string, AgentRunRecord>();

  async save(record: Readonly<AgentRunRecord>): Promise<void> {
    this.records.set(record.runId, structuredClone(record));
  }

  async getById(runId: string): Promise<Readonly<AgentRunRecord> | null> {
    const record = this.records.get(runId);
    return record === undefined ? null : structuredClone(record);
  }
}

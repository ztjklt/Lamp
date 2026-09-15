import type { AuditLogRepository, AuditRecord } from "../../observability/AuditLog.js";

export class InMemoryAuditLogRepository implements AuditLogRepository {
  private readonly records: AuditRecord[] = [];

  async append(record: Readonly<AuditRecord>): Promise<void> {
    this.records.push(structuredClone(record));
  }

  async listByRun(runId: string): Promise<ReadonlyArray<Readonly<AuditRecord>>> {
    return this.records.filter((record) => record.runId === runId).map((record) => structuredClone(record));
  }
}

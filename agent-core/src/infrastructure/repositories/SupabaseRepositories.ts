import { createHash } from "node:crypto";
import {
  MemoryCandidateSchema,
  MemoryQuerySchema,
  PreferenceMemorySchema,
  WorkingMemoryEntrySchema,
  type MemoryCandidate,
  type MemoryQuery,
  type PreferenceMemory,
  type PreferenceValue,
  type WorkingMemoryEntry,
} from "../../agent/memory/MemoryModels.js";
import { AgentRunRecordSchema, type AgentRunRecord } from "../../agent/schemas/AgentRun.js";
import { StateSnapshotSchema, type StateSnapshot } from "../../agent/state/StateSnapshot.js";
import type {
  MemoryCandidateRepository,
  MemoryRetriever,
  PreferenceMemoryRepository,
  WorkingMemoryStore,
} from "../../domain/repositories/MemoryRepositories.js";
import type { AgentRunRepository } from "../../domain/repositories/AgentRunRepository.js";
import type { PlanRevisionRepository } from "../../domain/repositories/PlanRevisionRepository.js";
import type { StateSnapshotRepository } from "../../domain/repositories/StateRepositories.js";
import { LampError } from "../../errors/LampError.js";
import { AuditRecordSchema, type AuditLogRepository, type AuditRecord } from "../../observability/AuditLog.js";
import { PlanRevisionSchema, type PlanRevision } from "../../planning/ReplanningTypes.js";
import { SupabaseRestClient } from "../supabase/SupabaseRestClient.js";

export class SupabaseAgentRunRepository implements AgentRunRepository {
  constructor(private readonly client: SupabaseRestClient) {}
  async save(record: Readonly<AgentRunRecord>): Promise<void> {
    const value = AgentRunRecordSchema.parse(record);
    await this.client.insert("agent_runs", {
      run_id: value.runId, trace_id: value.traceId, user_id: value.userId,
      session_id: value.sessionId, request_id: value.requestId, status: value.finalStatus,
      record: value, input_hash: hash(value.initialInput), started_at: value.startedAt,
      ended_at: value.endedAt ?? null,
    }, "run_id");
  }
  async getById(runId: string): Promise<Readonly<AgentRunRecord> | null> {
    const rows = await this.client.select<{ record: unknown }>("agent_runs", `run_id=eq.${encodeURIComponent(runId)}&select=record&limit=1`);
    return rows[0] === undefined ? null : AgentRunRecordSchema.parse(rows[0].record);
  }
}

export class SupabaseStateSnapshotRepository implements StateSnapshotRepository {
  constructor(private readonly client: SupabaseRestClient) {}
  async save(snapshot: Readonly<StateSnapshot>): Promise<void> {
    const value = StateSnapshotSchema.parse(snapshot);
    await this.client.insert("state_snapshots", {
      snapshot_id: value.snapshotId, user_id: value.userId, source_revision: value.sourceRevision,
      content_hash: hash(value), snapshot: value, captured_at: value.capturedAt,
    }, "snapshot_id");
  }
  async getById(snapshotId: string): Promise<Readonly<StateSnapshot> | null> {
    const rows = await this.client.select<{ snapshot: unknown }>("state_snapshots", `snapshot_id=eq.${encodeURIComponent(snapshotId)}&select=snapshot&limit=1`);
    return rows[0] === undefined ? null : StateSnapshotSchema.parse(rows[0].snapshot);
  }
}

export class SupabasePlanRevisionRepository implements PlanRevisionRepository {
  constructor(private readonly client: SupabaseRestClient) {}
  async append(revision: Readonly<PlanRevision>): Promise<void> {
    const value = PlanRevisionSchema.parse(revision);
    try {
      await this.client.insert("plan_revisions", {
        revision_id: value.revisionId, plan_id: value.planId, user_id: value.userId,
        revision: value.revision, previous_revision_id: value.previousRevisionId,
        source_event_id: value.sourceEventId, base_state_revision: value.baseStateRevision,
        status: value.status, revision_record: value, created_at: value.createdAt,
      });
    } catch (cause) {
      throw conflict("Plan revision append conflicted", cause);
    }
  }
  async getLatest(planId: string): Promise<Readonly<PlanRevision> | null> {
    const rows = await this.client.select<{ revision_record: unknown }>("plan_revisions", `plan_id=eq.${encodeURIComponent(planId)}&select=revision_record&order=revision.desc&limit=1`);
    return rows[0] === undefined ? null : PlanRevisionSchema.parse(rows[0].revision_record);
  }
  async list(planId: string): Promise<ReadonlyArray<Readonly<PlanRevision>>> {
    const rows = await this.client.select<{ revision_record: unknown }>("plan_revisions", `plan_id=eq.${encodeURIComponent(planId)}&select=revision_record&order=revision.asc`);
    return rows.map((row) => PlanRevisionSchema.parse(row.revision_record));
  }
}

export class SupabaseAuditLogRepository implements AuditLogRepository {
  constructor(private readonly client: SupabaseRestClient) {}
  async append(record: Readonly<AuditRecord>): Promise<void> {
    const value = AuditRecordSchema.parse(record);
    await this.client.insert("agent_actions", {
      id: value.auditId, user_id: value.userId, idempotency_key: value.callId,
      tool_name: value.toolName, tool_version: value.toolVersion,
      model: null, risk: mapRisk(value.riskLevel), validation_result: value.policyDecision ?? {},
      execution_result: value.outputSummary ?? null, run_id: value.runId, trace_id: value.traceId,
      input_hash: value.inputHash, policy_result: value.policyDecision ?? null,
      created_at: value.occurredAt,
    });
  }
  async listByRun(runId: string): Promise<ReadonlyArray<Readonly<AuditRecord>>> {
    const rows = await this.client.select<Record<string, unknown>>("agent_actions", `run_id=eq.${encodeURIComponent(runId)}&select=*&order=created_at.asc`);
    return rows.map((row) => AuditRecordSchema.parse({
      auditId: row["id"], callId: row["idempotency_key"], userId: row["user_id"], runId: row["run_id"],
      traceId: row["trace_id"], occurredAt: row["created_at"], toolName: row["tool_name"],
      toolVersion: row["tool_version"], riskLevel: unmapRisk(row["risk"]), inputHash: row["input_hash"],
      status: row["execution_result"] === null ? "failed" : "succeeded",
      ...(row["policy_result"] === null ? {} : { policyDecision: row["policy_result"] }),
      ...(row["execution_result"] === null ? {} : { outputSummary: row["execution_result"] }),
    }));
  }
}

export class SupabaseMemoryCandidateRepository implements MemoryCandidateRepository {
  constructor(private readonly client: SupabaseRestClient) {}
  async save(candidate: MemoryCandidate): Promise<void> {
    const value = MemoryCandidateSchema.parse(candidate);
    await this.client.insert("memory_candidates", rowForCandidate(value));
  }
  async getById(candidateId: string): Promise<MemoryCandidate | null> {
    const rows = await this.client.select<{ candidate: unknown }>("memory_candidates", `candidate_id=eq.${encodeURIComponent(candidateId)}&select=candidate&limit=1`);
    return rows[0] === undefined ? null : MemoryCandidateSchema.parse(rows[0].candidate);
  }
  async replace(candidate: MemoryCandidate): Promise<void> {
    const value = MemoryCandidateSchema.parse(candidate);
    const rows = await this.client.update("memory_candidates", `candidate_id=eq.${encodeURIComponent(value.candidateId)}`, rowForCandidate(value));
    if (rows.length !== 1) throw conflict("Memory candidate does not exist");
  }
}

export class SupabaseWorkingMemoryStore implements WorkingMemoryStore {
  constructor(private readonly client: SupabaseRestClient) {}
  async put(entry: WorkingMemoryEntry): Promise<void> {
    const value = WorkingMemoryEntrySchema.parse(entry);
    await this.client.insert("working_memory", {
      user_id: value.userId, session_id: value.sessionId, run_id: value.runId,
      memory_key: value.key, entry: value, expires_at: value.expiresAt,
    }, "user_id,session_id,run_id,memory_key");
  }
  async get(userId: string, sessionId: string, runId: string, key: string): Promise<WorkingMemoryEntry | null> {
    const query = `user_id=eq.${encodeURIComponent(userId)}&session_id=eq.${encodeURIComponent(sessionId)}&run_id=eq.${encodeURIComponent(runId)}&memory_key=eq.${encodeURIComponent(key)}&select=entry&limit=1`;
    const rows = await this.client.select<{ entry: unknown }>("working_memory", query);
    return rows[0] === undefined ? null : WorkingMemoryEntrySchema.parse(rows[0].entry);
  }
  async listForRun(userId: string, sessionId: string, runId: string): Promise<WorkingMemoryEntry[]> {
    const query = `user_id=eq.${encodeURIComponent(userId)}&session_id=eq.${encodeURIComponent(sessionId)}&run_id=eq.${encodeURIComponent(runId)}&select=entry&order=memory_key.asc`;
    return (await this.client.select<{ entry: unknown }>("working_memory", query)).map((row) => WorkingMemoryEntrySchema.parse(row.entry));
  }
  async clearExpired(now: string): Promise<number> {
    const rows = await this.client.delete<{ user_id: string }>("working_memory", `expires_at=lte.${encodeURIComponent(now)}&select=user_id`);
    return rows.length;
  }
}

export class SupabasePreferenceMemoryRepository implements PreferenceMemoryRepository, MemoryRetriever {
  constructor(private readonly client: SupabaseRestClient) {}
  async append(memory: PreferenceMemory, expectedCurrentVersion: number): Promise<void> {
    const value = PreferenceMemorySchema.parse(memory);
    const current = await this.getCurrent(value.userId, value.preference.key);
    if ((current?.version ?? 0) !== expectedCurrentVersion || value.version !== expectedCurrentVersion + 1) {
      throw new LampError({ code: "STALE_STATE", message: "Preference version changed", safeMessage: "偏好记忆已更新，请重试。", statusCode: 409 });
    }
    await this.client.insert("memories", {
      id: value.memoryId, user_id: value.userId, category: "preference", content: value,
      source: value.source, confidence: value.confidence, status: "confirmed",
      memory_key: value.preference.key, version: value.version,
      supersedes_id: value.supersedesMemoryId, created_at: value.createdAt, updated_at: value.updatedAt,
    });
  }
  async getCurrent(userId: string, key: PreferenceValue["key"]): Promise<PreferenceMemory | null> {
    const rows = await this.client.select<{ content: unknown }>("memories", `user_id=eq.${encodeURIComponent(userId)}&memory_key=eq.${encodeURIComponent(key)}&deleted_at=is.null&select=content&order=version.desc&limit=1`);
    return rows[0] === undefined ? null : PreferenceMemorySchema.parse(rows[0].content);
  }
  async getById(memoryId: string): Promise<PreferenceMemory | null> {
    const rows = await this.client.select<{ content: unknown }>("memories", `id=eq.${encodeURIComponent(memoryId)}&select=content&limit=1`);
    return rows[0] === undefined ? null : PreferenceMemorySchema.parse(rows[0].content);
  }
  async listCurrent(userId: string): Promise<PreferenceMemory[]> {
    const rows = await this.client.select<{ content: unknown }>("memories", `user_id=eq.${encodeURIComponent(userId)}&category=eq.preference&deleted_at=is.null&select=content&order=version.desc`);
    const current = new Map<string, PreferenceMemory>();
    for (const row of rows) {
      const memory = PreferenceMemorySchema.parse(row.content);
      if (!current.has(memory.preference.key)) current.set(memory.preference.key, memory);
    }
    return [...current.values()];
  }
  async listHistory(userId: string, key?: PreferenceValue["key"]): Promise<PreferenceMemory[]> {
    const keyFilter = key === undefined ? "" : `&memory_key=eq.${encodeURIComponent(key)}`;
    const rows = await this.client.select<{ content: unknown }>("memories", `user_id=eq.${encodeURIComponent(userId)}&category=eq.preference${keyFilter}&select=content&order=created_at.asc`);
    return rows.map((row) => PreferenceMemorySchema.parse(row.content));
  }
  async retrieve(rawQuery: MemoryQuery): Promise<PreferenceMemory[]> {
    const query = MemoryQuerySchema.parse(rawQuery);
    const keys = query.keys === undefined ? null : new Set(query.keys);
    const keywords = (query.keywords ?? []).map((word) => word.toLocaleLowerCase());
    return (await this.listCurrent(query.userId)).filter((memory) => {
      if (keys !== null && !keys.has(memory.preference.key)) return false;
      if (query.createdAfter !== undefined && memory.createdAt < query.createdAfter) return false;
      if (query.createdBefore !== undefined && memory.createdAt >= query.createdBefore) return false;
      return keywords.length === 0 || keywords.some((word) => JSON.stringify(memory).toLocaleLowerCase().includes(word));
    }).slice(0, query.limit);
  }
}

function rowForCandidate(value: MemoryCandidate): Record<string, unknown> {
  const status = value.status === "eligible" || value.status === "pending_confirmation" ? "pending" : value.status;
  return { candidate_id: value.candidateId, user_id: value.userId, status, candidate: value, created_at: value.createdAt, updated_at: value.updatedAt };
}

function hash(value: unknown): string {
  return createHash("sha256").update(typeof value === "string" ? value : JSON.stringify(value)).digest("hex");
}

function mapRisk(value: AuditRecord["riskLevel"]): "low" | "medium" | "high" {
  if (value === "READ_ONLY" || value === "LOW_MUTATION") return "low";
  if (value === "MEDIUM_MUTATION") return "medium";
  return "high";
}

function unmapRisk(value: unknown): AuditRecord["riskLevel"] {
  return value === "low" ? "READ_ONLY" : value === "medium" ? "MEDIUM_MUTATION" : "HIGH_MUTATION";
}

function conflict(message: string, cause?: unknown): LampError {
  return new LampError({ code: "CONFLICT_ERROR", message, safeMessage: "云端记录发生冲突。", statusCode: 409, cause });
}

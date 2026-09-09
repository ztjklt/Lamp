import type {
  MemoryCandidateRepository,
  MemoryRetriever,
  PreferenceMemoryRepository,
  WorkingMemoryStore,
} from "../../domain/repositories/MemoryRepositories.js";
import type {
  MemoryCandidate,
  MemoryQuery,
  PreferenceMemory,
  PreferenceValue,
  WorkingMemoryEntry,
} from "../../agent/memory/MemoryModels.js";
import { MemoryQuerySchema } from "../../agent/memory/MemoryModels.js";
import { LampError } from "../../errors/LampError.js";

export class InMemoryMemoryCandidateRepository implements MemoryCandidateRepository {
  private readonly candidates = new Map<string, MemoryCandidate>();

  async save(candidate: MemoryCandidate): Promise<void> {
    if (this.candidates.has(candidate.candidateId)) throw conflict("Memory candidate already exists");
    this.candidates.set(candidate.candidateId, structuredClone(candidate));
  }

  async getById(candidateId: string): Promise<MemoryCandidate | null> {
    return cloneOrNull(this.candidates.get(candidateId));
  }

  async replace(candidate: MemoryCandidate): Promise<void> {
    if (!this.candidates.has(candidate.candidateId)) throw conflict("Memory candidate does not exist");
    this.candidates.set(candidate.candidateId, structuredClone(candidate));
  }
}

export class InMemoryPreferenceMemoryRepository implements PreferenceMemoryRepository, MemoryRetriever {
  private readonly memories = new Map<string, PreferenceMemory>();

  async append(memory: PreferenceMemory, expectedCurrentVersion: number): Promise<void> {
    if (this.memories.has(memory.memoryId)) throw conflict("Preference memory already exists");
    const current = await this.getCurrent(memory.userId, memory.preference.key);
    if ((current?.version ?? 0) !== expectedCurrentVersion || memory.version !== expectedCurrentVersion + 1) {
      throw new LampError({
        code: "STALE_STATE",
        message: "Preference memory version changed before append",
        safeMessage: "偏好记忆已更新，请基于最新版本重试。",
        statusCode: 409,
      });
    }
    if ((current?.memoryId ?? null) !== memory.supersedesMemoryId) throw conflict("Invalid superseded preference memory");
    this.memories.set(memory.memoryId, structuredClone(memory));
  }

  async getCurrent(userId: string, key: PreferenceValue["key"]): Promise<PreferenceMemory | null> {
    const values = [...this.memories.values()]
      .filter((memory) => memory.userId === userId && memory.preference.key === key)
      .sort((left, right) => right.version - left.version || right.createdAt.localeCompare(left.createdAt));
    return cloneOrNull(values[0]);
  }

  async getById(memoryId: string): Promise<PreferenceMemory | null> {
    return cloneOrNull(this.memories.get(memoryId));
  }

  async listCurrent(userId: string): Promise<PreferenceMemory[]> {
    const byKey = new Map<PreferenceValue["key"], PreferenceMemory>();
    for (const memory of this.memories.values()) {
      if (memory.userId !== userId) continue;
      const current = byKey.get(memory.preference.key);
      if (!current || memory.version > current.version) byKey.set(memory.preference.key, memory);
    }
    return [...byKey.values()].sort((left, right) => left.preference.key.localeCompare(right.preference.key)).map(clone);
  }

  async listHistory(userId: string, key?: PreferenceValue["key"]): Promise<PreferenceMemory[]> {
    return [...this.memories.values()]
      .filter((memory) => memory.userId === userId && (key === undefined || memory.preference.key === key))
      .sort((left, right) => left.createdAt.localeCompare(right.createdAt) || left.version - right.version)
      .map(clone);
  }

  async retrieve(rawQuery: MemoryQuery): Promise<PreferenceMemory[]> {
    const query = MemoryQuerySchema.parse(rawQuery);
    const keys = query.keys ? new Set(query.keys) : null;
    const keywords = (query.keywords ?? []).map((keyword) => keyword.toLocaleLowerCase());
    return (await this.listCurrent(query.userId)).filter((memory) => {
      if (keys && !keys.has(memory.preference.key)) return false;
      if (query.createdAfter && memory.createdAt < query.createdAfter) return false;
      if (query.createdBefore && memory.createdAt >= query.createdBefore) return false;
      if (keywords.length === 0) return true;
      const text = JSON.stringify({ preference: memory.preference, evidence: memory.evidence }).toLocaleLowerCase();
      return keywords.some((keyword) => text.includes(keyword));
    }).slice(0, query.limit);
  }
}

export class InMemoryWorkingMemoryStore implements WorkingMemoryStore {
  private readonly entries = new Map<string, WorkingMemoryEntry>();

  async put(entry: WorkingMemoryEntry): Promise<void> {
    this.entries.set(compoundKey(entry.userId, entry.sessionId, entry.runId, entry.key), structuredClone(entry));
  }

  async get(userId: string, sessionId: string, runId: string, key: string): Promise<WorkingMemoryEntry | null> {
    return cloneOrNull(this.entries.get(compoundKey(userId, sessionId, runId, key)));
  }

  async listForRun(userId: string, sessionId: string, runId: string): Promise<WorkingMemoryEntry[]> {
    return [...this.entries.values()]
      .filter((entry) => entry.userId === userId && entry.sessionId === sessionId && entry.runId === runId)
      .sort((left, right) => left.key.localeCompare(right.key))
      .map(clone);
  }

  async clearExpired(now: string): Promise<number> {
    let cleared = 0;
    for (const [key, entry] of this.entries) {
      if (entry.expiresAt <= now) {
        this.entries.delete(key);
        cleared += 1;
      }
    }
    return cleared;
  }
}

function compoundKey(userId: string, sessionId: string, runId: string, key: string): string {
  return JSON.stringify([userId, sessionId, runId, key]);
}

function clone<T>(value: T): T {
  return structuredClone(value);
}

function cloneOrNull<T>(value: T | undefined): T | null {
  return value === undefined ? null : structuredClone(value);
}

function conflict(message: string): LampError {
  return new LampError({ code: "CONFLICT_ERROR", message, safeMessage: "记忆记录发生冲突。", statusCode: 409 });
}

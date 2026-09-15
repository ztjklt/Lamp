import type {
  MemoryCandidate,
  MemoryQuery,
  PreferenceMemory,
  PreferenceValue,
  WorkingMemoryEntry,
} from "../../agent/memory/MemoryModels.js";

export interface MemoryCandidateRepository {
  save(candidate: MemoryCandidate): Promise<void>;
  getById(candidateId: string): Promise<MemoryCandidate | null>;
  replace(candidate: MemoryCandidate): Promise<void>;
}

export interface PreferenceMemoryRepository {
  append(memory: PreferenceMemory, expectedCurrentVersion: number): Promise<void>;
  getCurrent(userId: string, key: PreferenceValue["key"]): Promise<PreferenceMemory | null>;
  getById(memoryId: string): Promise<PreferenceMemory | null>;
  listCurrent(userId: string): Promise<PreferenceMemory[]>;
  listHistory(userId: string, key?: PreferenceValue["key"]): Promise<PreferenceMemory[]>;
}

export interface WorkingMemoryStore {
  put(entry: WorkingMemoryEntry): Promise<void>;
  get(userId: string, sessionId: string, runId: string, key: string): Promise<WorkingMemoryEntry | null>;
  listForRun(userId: string, sessionId: string, runId: string): Promise<WorkingMemoryEntry[]>;
  clearExpired(now: string): Promise<number>;
}

/** Retrieval boundary for future RAG adapters. Phase 7 deliberately uses structured matching only. */
export interface MemoryRetriever {
  retrieve(query: MemoryQuery): Promise<PreferenceMemory[]>;
}

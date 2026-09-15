import type { Clock } from "../../infrastructure/clock/Clock.js";
import type { IdGenerator } from "../../infrastructure/id/IdGenerator.js";
import type {
  MemoryCandidateRepository,
  MemoryRetriever,
  PreferenceMemoryRepository,
} from "../../domain/repositories/MemoryRepositories.js";
import { LampError } from "../../errors/LampError.js";
import type { PolicyDecision } from "../tools/ToolResult.js";
import {
  MemoryCandidateInputSchema,
  MemoryCandidateSchema,
  MemoryQuerySchema,
  PreferenceMemorySchema,
  type MemoryCandidate,
  type MemoryCandidateInput,
  type MemoryQuery,
  type PreferenceMemory,
} from "./MemoryModels.js";
import { MemoryPolicy } from "./MemoryPolicy.js";

export interface MemoryProposal {
  candidate: MemoryCandidate;
  policyDecision: PolicyDecision;
}

export interface MemoryApprovalInput {
  userId: string;
  candidateId: string;
  approvedBy: "user" | "policy";
  expectedVersion?: number;
}

export class MemoryEngine implements MemoryRetriever {
  constructor(
    private readonly candidates: MemoryCandidateRepository,
    private readonly preferences: PreferenceMemoryRepository,
    private readonly policy: MemoryPolicy,
    private readonly clock: Clock,
    private readonly ids: IdGenerator,
  ) {}

  async propose(userId: string, rawInput: MemoryCandidateInput): Promise<MemoryProposal> {
    const input = MemoryCandidateInputSchema.parse(rawInput);
    const current = await this.preferences.getCurrent(userId, input.preference.key);
    const policyDecision = this.policy.evaluate(input, current);
    const now = this.clock.now().toString();
    const candidate = MemoryCandidateSchema.parse({
      ...input,
      candidateId: this.ids.next(),
      userId,
      type: "preference",
      createdAt: now,
      updatedAt: now,
      status: policyDecision.decision === "allow"
        ? "eligible"
        : policyDecision.decision === "ask_user" ? "pending_confirmation" : "rejected",
      policyReasonCode: policyDecision.reasonCode,
    });
    await this.candidates.save(candidate);
    return { candidate, policyDecision };
  }

  async approve(input: MemoryApprovalInput): Promise<PreferenceMemory> {
    const candidate = await this.candidates.getById(input.candidateId);
    if (!candidate || candidate.userId !== input.userId) throw notFoundOrOwned();
    if (candidate.status === "approved") {
      if (!candidate.promotedMemoryId) throw internal("Approved candidate has no promoted memory ID");
      const existing = await this.preferences.getById(candidate.promotedMemoryId);
      if (!existing || existing.userId !== input.userId) throw internal("Promoted preference memory is missing");
      return existing;
    }
    if (candidate.status === "rejected") throw denied(candidate.policyReasonCode);

    const current = await this.preferences.getCurrent(input.userId, candidate.preference.key);
    const decision = this.policy.evaluate(candidate, current);
    if (decision.decision === "deny") throw denied(decision.reasonCode);
    if (decision.decision === "ask_user" && input.approvedBy !== "user") {
      throw denied("USER_CONFIRMATION_REQUIRED");
    }
    if (input.expectedVersion !== undefined && input.expectedVersion !== (current?.version ?? 0)) {
      throw stale();
    }
    const now = this.clock.now().toString();
    const memory = PreferenceMemorySchema.parse({
      memoryId: this.ids.next(),
      userId: input.userId,
      type: "preference",
      preference: candidate.preference,
      version: (current?.version ?? 0) + 1,
      supersedesMemoryId: current?.memoryId ?? null,
      createdAt: now,
      updatedAt: now,
      confidence: candidate.confidence,
      source: candidate.source,
      explicitOrInferred: candidate.source === "user_explicit" ? "explicit" : "inferred",
      evidence: candidate.evidence,
      sourceCandidateId: candidate.candidateId,
    });
    await this.preferences.append(memory, current?.version ?? 0);
    await this.candidates.replace(MemoryCandidateSchema.parse({
      ...candidate,
      status: "approved",
      promotedMemoryId: memory.memoryId,
      updatedAt: now,
    }));
    return memory;
  }

  async reject(userId: string, candidateId: string): Promise<MemoryCandidate> {
    const candidate = await this.candidates.getById(candidateId);
    if (!candidate || candidate.userId !== userId) throw notFoundOrOwned();
    if (candidate.status === "approved") throw conflict("Approved memory candidate cannot be rejected");
    const rejected = MemoryCandidateSchema.parse({
      ...candidate,
      status: "rejected",
      policyReasonCode: "USER_REJECTED_MEMORY",
      updatedAt: this.clock.now().toString(),
    });
    await this.candidates.replace(rejected);
    return rejected;
  }

  async retrieve(rawQuery: MemoryQuery): Promise<PreferenceMemory[]> {
    const query = MemoryQuerySchema.parse(rawQuery);
    const values = await this.preferences.listCurrent(query.userId);
    const keys = query.keys ? new Set(query.keys) : null;
    const keywords = (query.keywords ?? []).map((keyword) => keyword.toLocaleLowerCase());
    return values.filter((memory) => {
      if (keys && !keys.has(memory.preference.key)) return false;
      if (query.createdAfter && memory.createdAt < query.createdAfter) return false;
      if (query.createdBefore && memory.createdAt >= query.createdBefore) return false;
      if (keywords.length === 0) return true;
      const text = JSON.stringify({ preference: memory.preference, evidence: memory.evidence }).toLocaleLowerCase();
      return keywords.some((keyword) => text.includes(keyword));
    }).slice(0, query.limit);
  }
}

function denied(reasonCode: string): LampError {
  return new LampError({ code: "POLICY_DENIED", message: reasonCode, safeMessage: "该记忆候选未获准写入长期偏好。", statusCode: 403 });
}

function stale(): LampError {
  return new LampError({ code: "STALE_STATE", message: "Preference version mismatch", safeMessage: "偏好记忆已更新，请重试。", statusCode: 409 });
}

function conflict(message: string): LampError {
  return new LampError({ code: "CONFLICT_ERROR", message, safeMessage: "记忆候选状态冲突。", statusCode: 409 });
}

function notFoundOrOwned(): LampError {
  return new LampError({ code: "AUTH_ERROR", message: "Memory candidate not found or owned by another user", safeMessage: "无法访问该记忆候选。", statusCode: 403 });
}

function internal(message: string): LampError {
  return new LampError({ code: "INTERNAL_ERROR", message, safeMessage: "记忆记录状态异常。" });
}

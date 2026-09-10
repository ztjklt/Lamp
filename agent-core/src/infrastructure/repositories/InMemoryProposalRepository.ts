import type { ProposalConfirmation, ProposalRepository, StoredProposal } from "../../domain/repositories/ProposalRepository.js";
import { ProposalConfirmationSchema, StoredProposalSchema } from "../../domain/repositories/ProposalRepository.js";
import { LampError } from "../../errors/LampError.js";

export class InMemoryProposalRepository implements ProposalRepository {
  private readonly records = new Map<string, StoredProposal>();
  private readonly confirmations = new Map<string, {
    requestHash: string;
    result: { proposalId: string; stateVersion: number; status: "applied" };
  }>();

  constructor(private readonly now: () => Date = () => new Date()) {}

  async save(raw: StoredProposal): Promise<void> {
    const proposal = StoredProposalSchema.parse(raw);
    if (this.records.has(proposal.proposalId)) throw conflict("proposal already exists");
    this.records.set(proposal.proposalId, structuredClone(proposal));
  }
  async getOwned(proposalId: string, userId: string): Promise<StoredProposal | null> {
    const proposal = this.records.get(proposalId);
    return proposal?.userId === userId ? structuredClone(proposal) : null;
  }
  async getByRequest(userId: string, requestId: string): Promise<StoredProposal | null> {
    const proposal = [...this.records.values()].find((candidate) =>
      candidate.userId === userId && candidate.requestId === requestId,
    );
    return proposal === undefined ? null : structuredClone(proposal);
  }
  async reject(proposalId: string, userId: string): Promise<StoredProposal> {
    const proposal = await this.requirePending(proposalId, userId);
    proposal.status = "rejected";
    this.records.set(proposalId, structuredClone(proposal));
    return proposal;
  }
  async confirm(raw: ProposalConfirmation): Promise<{ proposalId: string; stateVersion: number; status: "applied" }> {
    const input = ProposalConfirmationSchema.parse(raw);
    const key = `${input.userId}:${input.idempotencyKey}`;
    const previous = this.confirmations.get(key);
    const requestHash = confirmationRequestHash(input);
    if (previous !== undefined) {
      if (previous.requestHash !== requestHash) throw conflict("idempotency key reused with different confirmation content");
      return structuredClone(previous.result);
    }
    const proposal = await this.requirePending(input.proposalId, input.userId);
    if (proposal.expiresAt <= this.now().toISOString()) {
      proposal.status = "expired";
      this.records.set(proposal.proposalId, proposal);
      throw new LampError({ code: "STALE_STATE", message: "proposal expired", safeMessage: "调整方案已过期，请重新生成。", statusCode: 410 });
    }
    if (proposal.previewHash !== input.previewHash || proposal.confirmationTokenHash !== input.confirmationTokenHash) {
      throw new LampError({ code: "AUTH_ERROR", message: "proposal confirmation mismatch", safeMessage: "确认凭证无效。", statusCode: 403 });
    }
    if (proposal.expectedStateVersion !== input.expectedStateVersion) {
      throw new LampError({ code: "STALE_STATE", message: "proposal state version is stale", safeMessage: "任务或日程已变化，请重新生成方案。", statusCode: 409 });
    }
    proposal.status = "applied";
    this.records.set(proposal.proposalId, structuredClone(proposal));
    const result = { proposalId: proposal.proposalId, stateVersion: input.expectedStateVersion + 1, status: "applied" as const };
    this.confirmations.set(key, { requestHash, result });
    return structuredClone(result);
  }
  private async requirePending(proposalId: string, userId: string): Promise<StoredProposal> {
    const proposal = await this.getOwned(proposalId, userId);
    if (proposal === null) throw new LampError({ code: "AUTH_ERROR", message: "proposal not found", safeMessage: "无法访问该调整方案。", statusCode: 404 });
    if (proposal.status !== "pending") throw conflict("proposal is no longer pending");
    return proposal;
  }
}

function confirmationRequestHash(input: ProposalConfirmation): string {
  return JSON.stringify([
    input.proposalId,
    input.previewHash,
    input.confirmationTokenHash,
    input.expectedStateVersion,
  ]);
}

function conflict(message: string): LampError {
  return new LampError({ code: "CONFLICT_ERROR", message, safeMessage: "调整方案状态已经变化。", statusCode: 409 });
}

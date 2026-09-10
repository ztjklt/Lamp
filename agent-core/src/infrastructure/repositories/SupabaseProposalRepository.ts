import { ProposalConfirmationSchema, StoredProposalSchema, type ProposalConfirmation, type ProposalRepository, type StoredProposal } from "../../domain/repositories/ProposalRepository.js";
import { LampError } from "../../errors/LampError.js";
import { SupabaseRestClient } from "../supabase/SupabaseRestClient.js";

export class SupabaseProposalRepository implements ProposalRepository {
  constructor(private readonly client: SupabaseRestClient) {}
  async save(raw: StoredProposal): Promise<void> {
    const value = StoredProposalSchema.parse(raw);
    await this.client.insert("replan_proposals", {
      id: value.proposalId, user_id: value.userId, reason: value.kind, kind: value.kind,
      request_id: value.requestId, request_hash: value.requestHash,
      preview_hash: value.previewHash, source_fingerprint: value.sourceFingerprint,
      expected_state_version: value.expectedStateVersion, confirmation_token_hash: value.confirmationTokenHash,
      diff: { operations: value.operations }, status: value.status, scope: "local", trace: value.trace,
      response: value.response, expires_at: value.expiresAt, created_at: value.createdAt,
    });
  }
  async getOwned(proposalId: string, userId: string): Promise<StoredProposal | null> {
    const rows = await this.client.select<Record<string, unknown>>("replan_proposals", `id=eq.${encodeURIComponent(proposalId)}&user_id=eq.${encodeURIComponent(userId)}&select=*&limit=1`);
    return rows[0] === undefined ? null : fromRow(rows[0]);
  }
  async getByRequest(userId: string, requestId: string): Promise<StoredProposal | null> {
    const rows = await this.client.select<Record<string, unknown>>(
      "replan_proposals",
      `user_id=eq.${encodeURIComponent(userId)}&request_id=eq.${encodeURIComponent(requestId)}&select=*&limit=1`,
    );
    return rows[0] === undefined ? null : fromRow(rows[0]);
  }
  async reject(proposalId: string, userId: string): Promise<StoredProposal> {
    const rows = await this.client.update<Record<string, unknown>>("replan_proposals", `id=eq.${encodeURIComponent(proposalId)}&user_id=eq.${encodeURIComponent(userId)}&status=eq.pending`, { status: "rejected", rejected_at: new Date().toISOString() });
    if (rows[0] === undefined) throw conflict("proposal is not pending");
    return fromRow(rows[0]);
  }
  async confirm(raw: ProposalConfirmation): Promise<{ proposalId: string; stateVersion: number; status: "applied" }> {
    const input = ProposalConfirmationSchema.parse(raw);
    const result = await this.client.rpc<Record<string, unknown>>("confirm_agent_proposal", {
      p_user_id: input.userId,
      p_proposal_id: input.proposalId, p_preview_hash: input.previewHash,
      p_confirmation_token_hash: input.confirmationTokenHash,
      p_expected_state_version: input.expectedStateVersion, p_idempotency_key: input.idempotencyKey,
    });
    return { proposalId: String(result["proposalId"]), stateVersion: Number(result["stateVersion"]), status: "applied" };
  }
}

function fromRow(row: Record<string, unknown>): StoredProposal {
  const diff = row["diff"] as { operations?: unknown } | undefined;
  return StoredProposalSchema.parse({
    proposalId: row["id"], userId: row["user_id"], kind: row["kind"], requestId: row["request_id"], requestHash: row["request_hash"],
    sourceFingerprint: row["source_fingerprint"], expectedStateVersion: row["expected_state_version"],
    previewHash: row["preview_hash"], confirmationTokenHash: row["confirmation_token_hash"], status: row["status"],
    operations: diff?.operations ?? [], response: row["response"], trace: row["trace"], createdAt: row["created_at"], expiresAt: row["expires_at"],
  });
}
function conflict(message: string): LampError {
  return new LampError({ code: "CONFLICT_ERROR", message, safeMessage: "调整方案状态已经变化。", statusCode: 409 });
}

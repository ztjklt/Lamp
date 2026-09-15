import { createHmac } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { V2ProposalService } from "../src/api/V2ProposalService.js";
import type { AgentRunRepository } from "../src/domain/repositories/AgentRunRepository.js";
import type { ProposalConfirmation, ProposalRepository, StoredProposal } from "../src/domain/repositories/ProposalRepository.js";
import { LampError } from "../src/errors/LampError.js";
import { InMemoryProposalRepository } from "../src/infrastructure/repositories/InMemoryProposalRepository.js";

const ids = {
  request: "60000000-0000-4000-8000-000000000001",
  proposal: "60000000-0000-4000-8000-000000000002",
  block: "60000000-0000-4000-8000-000000000003",
  task: "60000000-0000-4000-8000-000000000004",
};
const fingerprint = "d".repeat(64);
const secret = "test-confirmation-secret-that-is-long-enough";

function response() {
  return {
    schemaVersion: 1, status: "proposal", requestId: ids.request,
    sourceFingerprint: fingerprint, commitRequired: true,
    proposal: {
      id: ids.proposal, title: "候选", blocks: [{ id: ids.block, taskId: ids.task,
        title: "高数", startsAt: "2030-01-01T12:00:00.000Z", endsAt: "2030-01-01T12:30:00.000Z",
        replacesBlockId: null, reasonCodes: ["USER_REQUESTED_REPLAN"] }], warnings: [],
    },
    diagnostics: ["ok"],
  };
}

function fixture() {
  const now = () => new Date("2030-01-01T10:00:00.000Z");
  const repository = new InMemoryProposalRepository(now);
  const plan = vi.fn(() => response());
  const service = new V2ProposalService(repository, {
    plan_day: plan,
    replan_incomplete: async () => response(),
    replan_language: async () => response(),
  }, secret, now);
  return { repository, service, plan };
}

describe("V2ProposalService", () => {
  it("wraps a v1 proposal with a short-lived confirmation boundary", async () => {
    const { repository, service, plan } = fixture();
    const result = await service.create("plan_day", { expectedStateVersion: 7, request: { any: "fixture" } }, "user-a");
    expect(result).toMatchObject({ schemaVersion: 2, status: "proposal", commitRequired: true,
      expectedStateVersion: 7, requestId: ids.request });
    expect(result["confirmationToken"]).toEqual(expect.any(String));
    expect(result["previewHash"]).toMatch(/^[a-f0-9]{64}$/);
    expect(plan).toHaveBeenCalledOnce();
    const stored = await repository.getOwned(ids.proposal, "user-a");
    expect(stored?.response).toMatchObject({ requestId: ids.request });
    expect(stored?.confirmationTokenHash).not.toBe(result["confirmationToken"]);
    expect(stored?.operations).toEqual([{ type: "upsert_schedule_block", id: ids.block,
      planNodeId: ids.task, title: "高数", startsAt: "2030-01-01T12:00:00.000Z", endsAt: "2030-01-01T12:30:00.000Z",
      reasonCodes: ["USER_REQUESTED_REPLAN"] }]);
  });

  it("commits a language-derived temporary state in the same proposal transaction", async () => {
    const now = () => new Date("2030-01-01T10:00:00.000Z");
    const repository = new InMemoryProposalRepository(now);
    const languageResponse = {
      ...response(),
      trace: { decision: { temporaryState: "tired" } },
    };
    const service = new V2ProposalService(repository, {
      plan_day: () => response(),
      replan_incomplete: async () => response(),
      replan_language: async () => languageResponse,
    }, secret, now);

    await service.create("replan_language", {
      expectedStateVersion: 7, request: { any: "fixture" },
    }, "user-a");

    const stored = await repository.getOwned(ids.proposal, "user-a");
    expect(stored?.operations).toEqual(expect.arrayContaining([
      expect.objectContaining({
        type: "set_temporary_state", title: "疲惫",
        expiresAt: "2030-01-02T10:00:00.000Z", workloadMultiplier: 0.55,
      }),
    ]));
  });

  it("requires matching token, preview hash, version, and owner", async () => {
    const { service } = fixture();
    const proposal = await service.create("plan_day", { expectedStateVersion: 7, request: {} }, "user-a");
    const body = { previewHash: proposal["previewHash"], confirmationToken: proposal["confirmationToken"],
      expectedStateVersion: 7, idempotencyKey: "confirm-1" };
    await expect(service.confirm(ids.proposal, body, "user-b")).rejects.toMatchObject({ code: "AUTH_ERROR" });
    await expect(service.confirm(ids.proposal, { ...body, expectedStateVersion: 8 }, "user-a")).rejects.toMatchObject({ code: "STALE_STATE" });
    await expect(service.confirm(ids.proposal, { ...body, confirmationToken: "x".repeat(32) }, "user-a")).rejects.toMatchObject({ code: "AUTH_ERROR" });
    await expect(service.confirm(ids.proposal, body, "user-a")).resolves.toMatchObject({ status: "applied", stateVersion: 8 });
  });

  it("returns the same confirmation result for an idempotent retry", async () => {
    const { service } = fixture();
    const proposal = await service.create("plan_day", { expectedStateVersion: 2, request: {} }, "user-a");
    const body = { previewHash: proposal["previewHash"], confirmationToken: proposal["confirmationToken"],
      expectedStateVersion: 2, idempotencyKey: "confirm-retry" };
    const first = await service.confirm(ids.proposal, body, "user-a");
    const second = await service.confirm(ids.proposal, body, "user-a");
    expect(second).toEqual(first);
  });

  it("rejects an idempotency key reused with different confirmation content", async () => {
    const { service } = fixture();
    const proposal = await service.create("plan_day", { expectedStateVersion: 2, request: {} }, "user-a");
    const body = { previewHash: proposal["previewHash"], confirmationToken: proposal["confirmationToken"],
      expectedStateVersion: 2, idempotencyKey: "confirm-content" };
    await service.confirm(ids.proposal, body, "user-a");
    await expect(service.confirm(ids.proposal, { ...body, previewHash: "a".repeat(64) }, "user-a"))
      .rejects.toMatchObject({ code: "CONFLICT_ERROR", statusCode: 409 });
  });

  it("returns the stored proposal for a repeated request ID without creating another record", async () => {
    const { service, plan } = fixture();
    const first = await service.create("plan_day", { expectedStateVersion: 7, request: {} }, "user-a");
    const second = await service.create("plan_day", { expectedStateVersion: 7, request: {} }, "user-a");
    expect(second).toMatchObject({ proposalId: ids.proposal, previewHash: first["previewHash"] });
    expect(second["confirmationToken"]).toBe(first["confirmationToken"]);
    expect(plan).toHaveBeenCalledTimes(2);
  });

  it("rejects a repeated request ID whose request body changed", async () => {
    const { service } = fixture();
    await service.create("plan_day", { expectedStateVersion: 7, request: { day: 1 } }, "user-a");
    await expect(service.create("plan_day", { expectedStateVersion: 7, request: { day: 2 } }, "user-a"))
      .rejects.toMatchObject({ code: "CONFLICT_ERROR", statusCode: 409 });
  });

  it("stores only an HMAC of the confirmation token", async () => {
    const { repository, service } = fixture();
    const proposal = await service.create("plan_day", { expectedStateVersion: 0, request: {} }, "user-a");
    const stored = await repository.getOwned(ids.proposal, "user-a");
    expect(stored?.confirmationTokenHash).toBe(createHmac("sha256", secret).update(String(proposal["confirmationToken"])).digest("hex"));
  });

  it("persists a privacy-safe run record for every proposal", async () => {
    const save = vi.fn<AgentRunRepository["save"]>();
    const runs: AgentRunRepository = { save, getById: async () => null };
    const now = () => new Date("2030-01-01T10:00:00.000Z");
    const service = new V2ProposalService(new InMemoryProposalRepository(now), {
      plan_day: () => response(),
      replan_incomplete: async () => response(),
      replan_language: async () => response(),
    }, secret, now, runs);
    await service.create("plan_day", {
      expectedStateVersion: 7,
      request: { privateTitle: "不要把正文写入运行记录" },
    }, "user-a");
    expect(save).toHaveBeenCalledOnce();
    expect(save.mock.calls[0]?.[0]).toMatchObject({
      userId: "user-a",
      requestId: ids.request,
      initialInput: expect.stringMatching(/^request-sha256:[a-f0-9]{64}$/),
      finalStatus: "confirmation_required",
      policyDecisions: [{ decision: "ask_user", reasonCode: "EXPLICIT_CONFIRMATION_REQUIRED" }],
    });
    expect(JSON.stringify(save.mock.calls[0]?.[0])).not.toContain("不要把正文写入运行记录");
  });

  it("converges on the winning database row when two instances race", async () => {
    const repository = new RacingProposalRepository();
    const now = () => new Date("2030-01-01T10:00:00.000Z");
    const service = new V2ProposalService(repository, {
      plan_day: () => response(),
      replan_incomplete: async () => response(),
      replan_language: async () => response(),
    }, secret, now);
    const result = await service.create("plan_day", { expectedStateVersion: 7, request: {} }, "user-a");
    expect(result).toMatchObject({ proposalId: ids.proposal, status: "pending" });
    expect(result["confirmationToken"]).toEqual(expect.any(String));
  });
});

class RacingProposalRepository implements ProposalRepository {
  private winner: StoredProposal | null = null;
  private reads = 0;

  async save(proposal: StoredProposal): Promise<void> {
    this.winner = structuredClone(proposal);
    throw new LampError({ code: "CONFLICT_ERROR", message: "unique request", statusCode: 409 });
  }
  async getOwned(): Promise<StoredProposal | null> { return this.winner; }
  async getByRequest(): Promise<StoredProposal | null> {
    this.reads += 1;
    return this.reads === 1 ? null : this.winner;
  }
  async reject(): Promise<StoredProposal> { throw new Error("not used"); }
  async confirm(_input: ProposalConfirmation): Promise<{ proposalId: string; stateVersion: number; status: "applied" }> {
    throw new Error("not used");
  }
}

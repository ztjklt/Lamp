import { createHash, createHmac } from "node:crypto";
import { z } from "zod";
import type { AgentRunRecord } from "../agent/schemas/AgentRun.js";
import type { AgentRunRepository } from "../domain/repositories/AgentRunRepository.js";
import type { ProposalKind, ProposalOperation, ProposalRepository, StoredProposal } from "../domain/repositories/ProposalRepository.js";
import { ProposalKindSchema } from "../domain/repositories/ProposalRepository.js";
import { LampError } from "../errors/LampError.js";
import { deterministicUuid } from "../planning/PlanningUtilities.js";

const CreateRequestSchema = z.object({ expectedStateVersion: z.number().int().nonnegative(), request: z.unknown() }).strict();
const ConfirmRequestSchema = z.object({
  previewHash: z.string().regex(/^[a-f0-9]{64}$/), confirmationToken: z.string().min(32).max(512),
  expectedStateVersion: z.number().int().nonnegative(), idempotencyKey: z.string().min(1).max(200),
}).strict();

export interface V2ProposalDelegates {
  plan_day(input: unknown): Promise<Record<string, unknown>> | Record<string, unknown>;
  replan_incomplete(input: unknown, userId: string): Promise<Record<string, unknown>>;
  replan_language(input: unknown, userId: string): Promise<Record<string, unknown>>;
}

export class V2ProposalService {
  constructor(
    private readonly repository: ProposalRepository,
    private readonly delegates: V2ProposalDelegates,
    private readonly confirmationSecret: string,
    private readonly now: () => Date = () => new Date(),
    private readonly runs?: AgentRunRepository,
  ) {
    if (confirmationSecret.length < 32) throw new Error("confirmation secret must contain at least 32 characters");
  }

  async create(kindInput: unknown, raw: unknown, userId: string): Promise<Record<string, unknown>> {
    const kind = ProposalKindSchema.parse(kindInput);
    const input = CreateRequestSchema.parse(raw);
    const response = await this.callDelegate(kind, input.request, userId);
    const status = stringField(response, "status");
    const requestId = stringField(response, "requestId", "eventId");
    const sourceFingerprint = stringField(response, "sourceFingerprint");
    const requestHash = stableHash(input.request);
    const existing = await this.repository.getByRequest(userId, requestId);
    if (existing !== null) {
      this.assertSameRequest(existing, kind, sourceFingerprint, input.expectedStateVersion, requestHash);
      await this.recordRun(existing, existing.response);
      return publicRecord(existing, existing.status === "pending" ? this.confirmationToken(existing) : undefined);
    }
    if (status !== "proposal") {
      await this.recordRun({ userId, kind, requestId, requestHash, sourceFingerprint,
        expectedStateVersion: input.expectedStateVersion }, response);
      return { schemaVersion: 2, kind, requestId, sourceFingerprint, expectedStateVersion: input.expectedStateVersion,
        ...(kind === "replan_incomplete" ? { eventId: requestId } : {}),
        commitRequired: true, status, proposal: null, trace: traceOf(response), diagnostics: diagnosticsOf(response) };
    }
    const proposal = objectField(response, "proposal");
    const proposalId = stringField(proposal, "id");
    const createdAt = this.now();
    const operations = operationsFor(response, createdAt);
    const previewHash = stableHash({ kind, requestId, sourceFingerprint, expectedStateVersion: input.expectedStateVersion, proposal, operations });
    const token = this.confirmationToken({ proposalId, userId, requestId, requestHash });
    const trace = traceOf(response);
    const record: StoredProposal = {
      proposalId, userId, kind, requestId, requestHash, sourceFingerprint, expectedStateVersion: input.expectedStateVersion,
      previewHash, confirmationTokenHash: this.tokenHash(token), status: "pending", operations,
      response, trace, createdAt: createdAt.toISOString(), expiresAt: new Date(createdAt.getTime() + 15 * 60_000).toISOString(),
    };
    try {
      await this.repository.save(record);
    } catch (error) {
      if (!(error instanceof LampError) || error.statusCode !== 409) throw error;
      const winner = await this.repository.getByRequest(userId, requestId);
      if (winner === null) throw error;
      this.assertSameRequest(winner, kind, sourceFingerprint, input.expectedStateVersion, requestHash);
      await this.recordRun(winner, winner.response);
      return publicRecord(winner, winner.status === "pending" ? this.confirmationToken(winner) : undefined);
    }
    await this.recordRun(record, response);
    return { schemaVersion: 2, kind, requestId, sourceFingerprint, expectedStateVersion: input.expectedStateVersion,
      ...(kind === "replan_incomplete" ? { eventId: requestId } : {}),
      commitRequired: true, status: "proposal", proposalId, previewHash, confirmationToken: token,
      expiresAt: record.expiresAt, proposal, trace, diagnostics: diagnosticsOf(response) };
  }

  async get(proposalId: string, userId: string): Promise<Record<string, unknown>> {
    return publicRecord(await this.owned(proposalId, userId));
  }
  async reject(proposalId: string, userId: string): Promise<Record<string, unknown>> {
    return publicRecord(await this.repository.reject(proposalId, userId));
  }
  async confirm(proposalId: string, raw: unknown, userId: string): Promise<Record<string, unknown>> {
    const input = ConfirmRequestSchema.parse(raw);
    const result = await this.repository.confirm({ proposalId, userId, previewHash: input.previewHash,
      confirmationTokenHash: this.tokenHash(input.confirmationToken), expectedStateVersion: input.expectedStateVersion,
      idempotencyKey: input.idempotencyKey });
    return { schemaVersion: 2, ...result };
  }

  private async owned(proposalId: string, userId: string): Promise<StoredProposal> {
    const record = await this.repository.getOwned(proposalId, userId);
    if (record === null) throw new LampError({ code: "AUTH_ERROR", message: "proposal not found", safeMessage: "无法访问该调整方案。", statusCode: 404 });
    return record;
  }
  private assertSameRequest(
    existing: StoredProposal,
    kind: ProposalKind,
    sourceFingerprint: string,
    expectedStateVersion: number,
    requestHash: string,
  ): void {
    if (existing.kind !== kind || existing.sourceFingerprint !== sourceFingerprint ||
        existing.expectedStateVersion !== expectedStateVersion || existing.requestHash !== requestHash) {
      throw new LampError({
        code: "CONFLICT_ERROR",
        message: "request ID was reused with different proposal content",
        safeMessage: "该请求编号已用于不同状态，请创建新请求。",
        statusCode: 409,
      });
    }
  }
  private async recordRun(
    identity: Pick<StoredProposal, "userId" | "kind" | "requestId" | "requestHash" | "sourceFingerprint" | "expectedStateVersion"> &
      Partial<Pick<StoredProposal, "proposalId" | "previewHash">>,
    response: Record<string, unknown>,
  ): Promise<void> {
    if (this.runs === undefined) return;
    await this.runs.save(agentRunFor(identity, response, this.now()));
  }
  private callDelegate(kind: ProposalKind, request: unknown, userId: string): Promise<Record<string, unknown>> | Record<string, unknown> {
    if (kind === "plan_day") return this.delegates.plan_day(request);
    if (kind === "replan_incomplete") return this.delegates.replan_incomplete(request, userId);
    return this.delegates.replan_language(request, userId);
  }
  private tokenHash(token: string): string {
    return createHmac("sha256", this.confirmationSecret).update(token).digest("hex");
  }
  private confirmationToken(identity: Pick<StoredProposal, "proposalId" | "userId" | "requestId" | "requestHash">): string {
    return createHmac("sha256", this.confirmationSecret)
      .update(`${identity.userId}:${identity.requestId}:${identity.proposalId}:${identity.requestHash}`)
      .digest("base64url");
  }
}

function agentRunFor(
  identity: Pick<StoredProposal, "userId" | "kind" | "requestId" | "requestHash" | "sourceFingerprint" | "expectedStateVersion"> &
    Partial<Pick<StoredProposal, "proposalId" | "previewHash">>,
  response: Record<string, unknown>,
  occurredAt: Date,
): AgentRunRecord {
  const timestamp = occurredAt.toISOString();
  const trace = traceOf(response);
  const model = objectFieldOptional(trace, "model");
  const usage = objectFieldOptional(trace, "usage");
  const diagnostics = diagnosticsOf(response);
  const hasProposal = response["status"] === "proposal";
  const traceId = uuidField(trace, "traceId") ?? deterministicUuid(identity.userId, identity.requestId, "v2-proposal-trace");
  const runId = deterministicUuid(identity.userId, identity.requestId, "v2-proposal-run");
  const inputTokens = numberField(usage, "inputTokens") ?? 0;
  const outputTokens = numberField(usage, "outputTokens") ?? 0;
  const cacheHitTokens = numberField(usage, "cacheHitTokens") ?? 0;
  const cacheMissTokens = numberField(usage, "cacheMissTokens") ?? 0;
  const modelName = stringFieldOptional(model, "model");
  const modelCalls = modelName === undefined ? [] : [{
    id: deterministicUuid(runId, "model-call"),
    provider: stringFieldOptional(model, "provider") ?? "unknown",
    model: modelName,
    startedAt: timestamp,
    endedAt: timestamp,
    status: "succeeded" as const,
    inputTokens,
    outputTokens,
    cacheHitTokens,
    cacheMissTokens,
    latencyMs: Math.max(0, Math.round(numberField(trace, "modelLatencyMs") ?? 0)),
  }];
  return {
    runId,
    traceId,
    userId: identity.userId,
    sessionId: `proposal:${identity.kind}`,
    requestId: identity.requestId,
    startedAt: timestamp,
    endedAt: timestamp,
    initialInput: `request-sha256:${identity.requestHash}`,
    decisions: [],
    modelCalls,
    toolCalls: [],
    policyDecisions: [{
      policyId: "mutation-confirmation-v2",
      decision: "ask_user",
      reasonCode: "EXPLICIT_CONFIRMATION_REQUIRED",
      occurredAt: timestamp,
    }],
    plannerRuns: [{
      id: deterministicUuid(runId, "planner-run"),
      startedAt: timestamp,
      endedAt: timestamp,
      status: hasProposal ? "success" : "no_feasible_plan",
      diagnostics,
    }],
    traceSteps: [
      { sequence: 1, type: "StateBuilt", occurredAt: timestamp, referenceId: identity.sourceFingerprint },
      ...(modelCalls.length === 0 ? [] : [{ sequence: 2, type: "LLMCall" as const, occurredAt: timestamp, referenceId: modelCalls[0]!.id }]),
      { sequence: modelCalls.length === 0 ? 2 : 3, type: "PlanValidated", occurredAt: timestamp,
        ...(identity.proposalId === undefined ? {} : { referenceId: identity.proposalId }) },
      { sequence: modelCalls.length === 0 ? 3 : 4, type: "PolicyChecked", occurredAt: timestamp,
        referenceId: "mutation-confirmation-v2" },
      { sequence: modelCalls.length === 0 ? 4 : 5, type: "AgentFinished", occurredAt: timestamp },
    ],
    finalStatus: hasProposal ? "confirmation_required" : "safe_aborted",
    finalOutput: {
      schemaVersion: 2,
      kind: identity.kind,
      status: String(response["status"] ?? "unknown"),
      sourceFingerprint: identity.sourceFingerprint,
      expectedStateVersion: identity.expectedStateVersion,
      ...(identity.proposalId === undefined ? {} : { proposalId: identity.proposalId }),
      ...(identity.previewHash === undefined ? {} : { previewHash: identity.previewHash }),
    },
    tokenUsage: { input: inputTokens, output: outputTokens, cacheHit: cacheHitTokens, cacheMiss: cacheMissTokens },
    estimatedCost: Math.max(0, numberField(trace, "estimatedCost") ?? 0),
  };
}

function operationsFor(response: Record<string, unknown>, createdAt: Date): ProposalOperation[] {
  const proposal = objectField(response, "proposal");
  const blocks = arrayField(proposal, "blocks").map(objectValue);
  const changes = arrayField(proposal, "changes", false).map(objectValue);
  const byProposed = new Map<string, Record<string, unknown>>();
  for (const change of changes) {
    const proposed = optionalStringField(change, "proposedBlockId");
    if (proposed !== undefined) byProposed.set(proposed, change);
  }
  const operations: ProposalOperation[] = [];
  for (const block of blocks) {
    const id = stringField(block, "id");
    const change = byProposed.get(id);
    if (changes.length > 0 && change === undefined) continue;
    const replaces = optionalStringField(block, "replacesBlockId") ?? (change && optionalStringField(change, "previousBlockId"));
    operations.push({ type: "upsert_schedule_block", id, planNodeId: stringField(block, "taskId"), title: stringField(block, "title"),
      startsAt: stringField(block, "startsAt"), endsAt: stringField(block, "endsAt"),
      ...(replaces === undefined ? {} : { replacesBlockId: replaces }), reasonCodes: stringArray(block["reasonCodes"]) });
  }
  for (const change of changes) {
    if (change["type"] === "REMOVE") {
      const id = optionalStringField(change, "previousBlockId");
      if (id !== undefined) operations.push({ type: "remove_schedule_block", id });
    }
  }
  const trace = optionalObjectValue(response["trace"]);
  const decision = optionalObjectValue(trace?.["decision"]);
  if (decision?.["temporaryState"] === "tired") {
    operations.push({
      type: "set_temporary_state",
      id: deterministicUuid(stringField(proposal, "id"), "temporary-state", "tired"),
      title: "疲惫",
      expiresAt: new Date(createdAt.getTime() + 24 * 60 * 60_000).toISOString(),
      workloadMultiplier: 0.55,
    });
  }
  return operations;
}

function optionalObjectValue(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function publicRecord(record: StoredProposal, confirmationToken?: string): Record<string, unknown> {
  return { schemaVersion: 2, proposalId: record.proposalId, kind: record.kind, requestId: record.requestId,
    ...(record.kind === "replan_incomplete" ? { eventId: record.requestId } : {}),
    sourceFingerprint: record.sourceFingerprint, expectedStateVersion: record.expectedStateVersion,
    previewHash: record.previewHash, status: record.status, expiresAt: record.expiresAt,
    proposal: record.response["proposal"] ?? null, trace: record.trace, diagnostics: diagnosticsOf(record.response),
    ...(confirmationToken === undefined ? {} : { confirmationToken }) };
}
function diagnosticsOf(response: Record<string, unknown>): string[] {
  const diagnostics = response["diagnostics"];
  return Array.isArray(diagnostics) ? diagnostics.filter((item): item is string => typeof item === "string") : [];
}
function traceOf(response: Record<string, unknown>): Record<string, unknown> {
  const trace = response["trace"];
  return trace !== null && typeof trace === "object" && !Array.isArray(trace)
    ? trace as Record<string, unknown> : { diagnostics: response["diagnostics"] ?? [] };
}
function stableHash(value: unknown): string {
  return createHash("sha256").update(stableStringify(value)).digest("hex");
}
function stableStringify(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (value !== null && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, child]) => `${JSON.stringify(key)}:${stableStringify(child)}`).join(",")}}`;
  return JSON.stringify(value) ?? "null";
}
function objectField(value: Record<string, unknown>, key: string): Record<string, unknown> { return objectValue(value[key]); }
function objectFieldOptional(value: Record<string, unknown> | undefined, key: string): Record<string, unknown> | undefined {
  const field = value?.[key];
  return field !== null && typeof field === "object" && !Array.isArray(field)
    ? field as Record<string, unknown> : undefined;
}
function objectValue(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid proposal object");
  return value as Record<string, unknown>;
}
function arrayField(value: Record<string, unknown>, key: string, required = true): unknown[] {
  const field = value[key];
  if (field === undefined && !required) return [];
  if (!Array.isArray(field)) throw new Error(`invalid ${key}`);
  return field;
}
function stringField(value: Record<string, unknown>, ...keys: string[]): string {
  for (const key of keys) if (typeof value[key] === "string") return value[key];
  throw new Error(`missing ${keys.join("/")}`);
}
function stringFieldOptional(value: Record<string, unknown> | undefined, key: string): string | undefined {
  return typeof value?.[key] === "string" ? value[key] as string : undefined;
}
function uuidField(value: Record<string, unknown>, key: string): string | undefined {
  const field = stringFieldOptional(value, key);
  return field !== undefined && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(field)
    ? field : undefined;
}
function numberField(value: Record<string, unknown> | undefined, key: string): number | undefined {
  const field = value?.[key];
  return typeof field === "number" && Number.isFinite(field) ? field : undefined;
}
function optionalStringField(value: Record<string, unknown>, key: string): string | undefined { return typeof value[key] === "string" ? value[key] : undefined; }
function stringArray(value: unknown): string[] { return Array.isArray(value) && value.every((item) => typeof item === "string") ? value : []; }

import { createHash } from "node:crypto";
import { z } from "zod";
import { LampError } from "../errors/LampError.js";
import type { Clock } from "../infrastructure/clock/Clock.js";
import type { IdGenerator } from "../infrastructure/id/IdGenerator.js";
import { ERROR_CODES } from "../errors/ErrorCode.js";
import { UUIDSchema } from "../agent/schemas/Common.js";
import { PolicyDecisionSchema, type PolicyDecision } from "../agent/tools/ToolResult.js";

export const AuditRecordSchema = z.object({
  auditId: UUIDSchema,
  callId: UUIDSchema,
  userId: z.string().min(1),
  runId: UUIDSchema,
  traceId: UUIDSchema,
  occurredAt: z.iso.datetime(),
  toolName: z.string().min(1),
  toolVersion: z.number().int().positive(),
  riskLevel: z.enum(["READ_ONLY", "LOW_MUTATION", "MEDIUM_MUTATION", "HIGH_MUTATION", "IRREVERSIBLE"]),
  inputHash: z.string().regex(/^[a-f0-9]{64}$/),
  status: z.enum(["succeeded", "confirmation_required", "denied", "failed"]),
  policyDecision: PolicyDecisionSchema.optional(),
  errorCode: z.enum(ERROR_CODES).optional(),
  outputSummary: z.object({
    itemCount: z.number().int().nonnegative().optional(),
    hasResult: z.boolean(),
  }).strict().optional(),
}).strict();

export type AuditRecord = z.infer<typeof AuditRecordSchema>;

export interface AuditLogRepository {
  append(record: Readonly<AuditRecord>): Promise<void>;
  listByRun(runId: string): Promise<ReadonlyArray<Readonly<AuditRecord>>>;
}

export interface WriteAuditInput {
  callId: string;
  userId: string;
  runId: string;
  traceId: string;
  toolName: string;
  toolVersion: number;
  riskLevel: AuditRecord["riskLevel"];
  input: unknown;
  status: AuditRecord["status"];
  policyDecision?: PolicyDecision;
  errorCode?: AuditRecord["errorCode"];
  output?: unknown;
}

export class AuditLog {
  constructor(
    private readonly repository: AuditLogRepository,
    private readonly clock: Clock,
    private readonly ids: IdGenerator,
  ) {}

  async write(input: WriteAuditInput): Promise<AuditRecord> {
    const record = AuditRecordSchema.parse({
      auditId: this.ids.next(),
      callId: input.callId,
      userId: input.userId,
      runId: input.runId,
      traceId: input.traceId,
      occurredAt: this.clock.now().toString(),
      toolName: input.toolName,
      toolVersion: input.toolVersion,
      riskLevel: input.riskLevel,
      inputHash: hashAuditValue(input.input),
      status: input.status,
      ...(input.policyDecision === undefined ? {} : { policyDecision: input.policyDecision }),
      ...(input.errorCode === undefined ? {} : { errorCode: input.errorCode }),
      ...(input.output === undefined ? {} : { outputSummary: summarizeOutput(input.output) }),
    });
    try {
      await this.repository.append(record);
    } catch (error) {
      throw new LampError({
        code: "DATABASE_ERROR",
        message: "Audit record could not be persisted",
        safeMessage: "安全审计暂时不可用。",
        retryable: true,
        statusCode: 503,
        cause: error,
      });
    }
    return record;
  }
}

export function hashAuditValue(value: unknown): string {
  return createHash("sha256").update(stableStringify(value)).digest("hex");
}

function stableStringify(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (value && typeof value === "object") {
    const entries = Object.entries(value).sort(([left], [right]) => left.localeCompare(right));
    return `{${entries.map(([key, item]) => `${JSON.stringify(key)}:${stableStringify(item)}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

function summarizeOutput(output: unknown): { itemCount?: number; hasResult: boolean } {
  if (Array.isArray(output)) return { itemCount: output.length, hasResult: true };
  if (output && typeof output === "object") {
    const firstArray = Object.values(output).find(Array.isArray);
    return firstArray ? { itemCount: firstArray.length, hasResult: true } : { hasResult: true };
  }
  return { hasResult: output !== null && output !== undefined };
}

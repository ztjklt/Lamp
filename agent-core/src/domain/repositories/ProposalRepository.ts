import { z } from "zod";
import { JsonObjectSchema, UUIDSchema } from "../../agent/schemas/Common.js";

export const ProposalKindSchema = z.enum(["plan_day", "replan_incomplete", "replan_language"]);
export const ProposalOperationSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("upsert_schedule_block"), id: UUIDSchema, planNodeId: UUIDSchema,
    title: z.string().min(1).max(240),
    startsAt: z.iso.datetime(), endsAt: z.iso.datetime(), replacesBlockId: UUIDSchema.optional(),
    reasonCodes: z.array(z.string()).default([]),
  }).strict(),
  z.object({ type: z.literal("remove_schedule_block"), id: UUIDSchema }).strict(),
]);

export const StoredProposalSchema = z.object({
  proposalId: UUIDSchema, userId: z.string().min(1), kind: ProposalKindSchema,
  requestId: z.string().min(1), requestHash: z.string().regex(/^[a-f0-9]{64}$/),
  sourceFingerprint: z.string().regex(/^[a-f0-9]{64}$/),
  expectedStateVersion: z.number().int().nonnegative(), previewHash: z.string().regex(/^[a-f0-9]{64}$/),
  confirmationTokenHash: z.string().regex(/^[a-f0-9]{64}$/),
  status: z.enum(["pending", "applied", "rejected", "expired"]),
  operations: z.array(ProposalOperationSchema), response: JsonObjectSchema, trace: JsonObjectSchema,
  createdAt: z.iso.datetime(), expiresAt: z.iso.datetime(),
}).strict();

export const ProposalConfirmationSchema = z.object({
  proposalId: UUIDSchema, userId: z.string().min(1), previewHash: z.string().regex(/^[a-f0-9]{64}$/),
  confirmationTokenHash: z.string().regex(/^[a-f0-9]{64}$/), expectedStateVersion: z.number().int().nonnegative(),
  idempotencyKey: z.string().min(1).max(200),
}).strict();

export type StoredProposal = z.infer<typeof StoredProposalSchema>;
export type ProposalKind = z.infer<typeof ProposalKindSchema>;
export type ProposalOperation = z.infer<typeof ProposalOperationSchema>;
export type ProposalConfirmation = z.infer<typeof ProposalConfirmationSchema>;

export interface ProposalRepository {
  save(proposal: StoredProposal): Promise<void>;
  getOwned(proposalId: string, userId: string): Promise<StoredProposal | null>;
  getByRequest(userId: string, requestId: string): Promise<StoredProposal | null>;
  reject(proposalId: string, userId: string): Promise<StoredProposal>;
  confirm(input: ProposalConfirmation): Promise<Readonly<{ proposalId: string; stateVersion: number; status: "applied" }>>;
}

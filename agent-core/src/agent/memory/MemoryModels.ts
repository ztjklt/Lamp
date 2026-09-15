import { z } from "zod";
import { JsonObjectSchema, UUIDSchema } from "../schemas/Common.js";
import { UTCInstantSchema } from "../state/StateModels.js";

const LocalTimeSchema = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/);

export const PREFERENCE_KEYS = [
  "preferred_sleep_time",
  "preferred_wake_time",
  "default_reminder_minutes",
  "preferred_focus_duration",
  "preferred_break_duration",
  "morning_study_preference",
  "evening_study_preference",
  "preferred_study_period",
] as const;

export const PreferenceValueSchema = z.discriminatedUnion("key", [
  z.object({ key: z.literal("preferred_sleep_time"), value: LocalTimeSchema.nullable() }).strict(),
  z.object({ key: z.literal("preferred_wake_time"), value: LocalTimeSchema.nullable() }).strict(),
  z.object({ key: z.literal("default_reminder_minutes"), value: z.number().int().min(0).max(1_440) }).strict(),
  z.object({ key: z.literal("preferred_focus_duration"), value: z.number().int().min(5).max(480) }).strict(),
  z.object({ key: z.literal("preferred_break_duration"), value: z.number().int().min(0).max(180) }).strict(),
  z.object({ key: z.literal("morning_study_preference"), value: z.number().min(0).max(1) }).strict(),
  z.object({ key: z.literal("evening_study_preference"), value: z.number().min(0).max(1) }).strict(),
  z.object({ key: z.literal("preferred_study_period"), value: z.enum(["morning", "afternoon", "evening"]) }).strict(),
]);

export const MemoryEvidenceSchema = z.object({
  sourceType: z.enum(["user_message", "behavior", "domain_event", "tool_result"]),
  referenceId: z.string().min(1).max(200),
  observedAt: UTCInstantSchema,
  summary: z.string().min(1).max(500),
}).strict();

const CandidateCoreSchema = z.object({
  preference: PreferenceValueSchema,
  confidence: z.number().min(0).max(1),
  source: z.enum(["user_explicit", "user_inferred", "behavioral"]),
  evidence: z.array(MemoryEvidenceSchema).min(1).max(20),
  reasonCodes: z.array(z.string().regex(/^[A-Z][A-Z0-9_]*$/)).min(1).max(20),
}).strict();

export const MemoryCandidateInputSchema = CandidateCoreSchema;

export const MemoryCandidateSchema = CandidateCoreSchema.extend({
  candidateId: UUIDSchema,
  userId: z.string().min(1),
  type: z.literal("preference"),
  createdAt: UTCInstantSchema,
  updatedAt: UTCInstantSchema,
  status: z.enum(["eligible", "pending_confirmation", "rejected", "approved"]),
  promotedMemoryId: UUIDSchema.optional(),
  policyReasonCode: z.string().regex(/^[A-Z][A-Z0-9_]*$/),
}).strict();

export const PreferenceMemorySchema = z.object({
  memoryId: UUIDSchema,
  userId: z.string().min(1),
  type: z.literal("preference"),
  preference: PreferenceValueSchema,
  version: z.number().int().positive(),
  supersedesMemoryId: UUIDSchema.nullable(),
  createdAt: UTCInstantSchema,
  updatedAt: UTCInstantSchema,
  confidence: z.number().min(0).max(1),
  source: z.enum(["user_explicit", "user_inferred", "behavioral"]),
  explicitOrInferred: z.enum(["explicit", "inferred"]),
  evidence: z.array(MemoryEvidenceSchema).min(1).max(20),
  sourceCandidateId: UUIDSchema,
}).strict();

export const WorkingMemoryEntrySchema = z.object({
  workingMemoryId: UUIDSchema,
  userId: z.string().min(1),
  sessionId: z.string().min(1),
  runId: UUIDSchema,
  key: z.string().regex(/^[a-z][a-z0-9_]{1,79}$/),
  value: JsonObjectSchema,
  createdAt: UTCInstantSchema,
  updatedAt: UTCInstantSchema,
  expiresAt: UTCInstantSchema,
}).strict().refine((entry) => Date.parse(entry.expiresAt) > Date.parse(entry.updatedAt), {
  path: ["expiresAt"],
  message: "working memory expiration must be after its update time",
});

export const MemoryQuerySchema = z.object({
  userId: z.string().min(1),
  keys: z.array(z.enum(PREFERENCE_KEYS)).max(20).optional(),
  keywords: z.array(z.string().trim().min(1).max(100)).max(20).optional(),
  createdAfter: UTCInstantSchema.optional(),
  createdBefore: UTCInstantSchema.optional(),
  limit: z.number().int().min(1).max(100).default(20),
}).strict().refine((query) => query.createdAfter === undefined || query.createdBefore === undefined ||
  Date.parse(query.createdBefore) > Date.parse(query.createdAfter), "createdBefore must be after createdAfter");

export type PreferenceValue = z.infer<typeof PreferenceValueSchema>;
export type MemoryEvidence = z.infer<typeof MemoryEvidenceSchema>;
export type MemoryCandidateInput = z.infer<typeof MemoryCandidateInputSchema>;
export type MemoryCandidate = z.infer<typeof MemoryCandidateSchema>;
export type PreferenceMemory = z.infer<typeof PreferenceMemorySchema>;
export type WorkingMemoryEntry = z.infer<typeof WorkingMemoryEntrySchema>;
export type MemoryQuery = z.infer<typeof MemoryQuerySchema>;

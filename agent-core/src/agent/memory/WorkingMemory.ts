import { z } from "zod";
import type { Clock } from "../../infrastructure/clock/Clock.js";
import type { IdGenerator } from "../../infrastructure/id/IdGenerator.js";
import type { WorkingMemoryStore } from "../../domain/repositories/MemoryRepositories.js";
import { JsonObjectSchema, UUIDSchema } from "../schemas/Common.js";
import { WorkingMemoryEntrySchema, type WorkingMemoryEntry } from "./MemoryModels.js";

const PutWorkingMemorySchema = z.object({
  userId: z.string().min(1),
  sessionId: z.string().min(1),
  runId: UUIDSchema,
  key: z.string().regex(/^[a-z][a-z0-9_]{1,79}$/),
  value: JsonObjectSchema,
  ttlMinutes: z.number().int().min(1).max(1_440).default(120),
}).strict();

export class WorkingMemory {
  constructor(
    private readonly store: WorkingMemoryStore,
    private readonly clock: Clock,
    private readonly ids: IdGenerator,
  ) {}

  async put(rawInput: z.input<typeof PutWorkingMemorySchema>): Promise<WorkingMemoryEntry> {
    const input = PutWorkingMemorySchema.parse(rawInput);
    await this.store.clearExpired(this.clock.now().toString());
    const existing = await this.store.get(input.userId, input.sessionId, input.runId, input.key);
    const now = this.clock.now();
    const entry = WorkingMemoryEntrySchema.parse({
      workingMemoryId: existing?.workingMemoryId ?? this.ids.next(),
      userId: input.userId,
      sessionId: input.sessionId,
      runId: input.runId,
      key: input.key,
      value: input.value,
      createdAt: existing?.createdAt ?? now.toString(),
      updatedAt: now.toString(),
      expiresAt: now.add({ minutes: input.ttlMinutes }).toString(),
    });
    await this.store.put(entry);
    return entry;
  }

  async listForRun(userId: string, sessionId: string, runId: string): Promise<WorkingMemoryEntry[]> {
    await this.store.clearExpired(this.clock.now().toString());
    return this.store.listForRun(userId, sessionId, runId);
  }
}

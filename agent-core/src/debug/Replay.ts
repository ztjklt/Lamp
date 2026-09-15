import { createHash } from "node:crypto";
import { z } from "zod";
import { AgentRequestSchema } from "../agent/orchestrator/AgentOrchestrator.js";
import { AgentResponseSchema, type AgentResponse } from "../agent/schemas/AgentResponse.js";
import { UUIDSchema, TimestampSchema } from "../agent/schemas/Common.js";
import { StateSnapshotSchema } from "../agent/state/StateSnapshot.js";
import type { LLMProvider } from "../llm/LLMProvider.js";
import { LLMResponseSchema, type LLMResponse } from "../llm/LLMResponse.js";
import { LampError } from "../errors/LampError.js";

const ReplayModelResponseSchema = LLMResponseSchema.omit({ reasoningContent: true });
const ComparableResponseSchema = AgentResponseSchema.omit({ runId: true });

export const ReplayBundleSchema = z.object({
  replayId: UUIDSchema,
  version: z.literal(1),
  capturedAt: TimestampSchema,
  request: AgentRequestSchema,
  state: StateSnapshotSchema,
  modelResponses: z.array(ReplayModelResponseSchema).min(1).max(32),
  expectedResponse: ComparableResponseSchema,
  expectedHash: z.string().regex(/^[a-f0-9]{64}$/),
}).strict();

export type ReplayBundle = z.infer<typeof ReplayBundleSchema>;

export interface ReplayExecution {
  response: AgentResponse;
}

export interface ReplayTarget {
  execute(bundle: ReplayBundle, provider: LLMProvider): Promise<ReplayExecution>;
}

export interface ReplayResult {
  replayId: string;
  matched: boolean;
  expectedHash: string;
  actualHash: string;
  response: AgentResponse;
}

export class ReplayRecorder {
  create(input: {
    replayId: string;
    capturedAt: string;
    request: z.input<typeof AgentRequestSchema>;
    state: z.input<typeof StateSnapshotSchema>;
    modelResponses: readonly LLMResponse[];
    response: AgentResponse;
  }): ReplayBundle {
    const expectedResponse = comparable(input.response);
    return ReplayBundleSchema.parse({
      replayId: input.replayId,
      version: 1,
      capturedAt: input.capturedAt,
      request: input.request,
      state: input.state,
      modelResponses: input.modelResponses.map(({ reasoningContent: _reasoning, ...response }) => response),
      expectedResponse,
      expectedHash: hashValue(expectedResponse),
    });
  }
}

export class ReplayProvider implements LLMProvider {
  readonly name = "replay";
  private readonly queue: LLMResponse[];

  constructor(responses: ReplayBundle["modelResponses"]) {
    this.queue = responses.map((response) => LLMResponseSchema.parse(response));
  }

  async generate(): Promise<LLMResponse> {
    const response = this.queue.shift();
    if (!response) throw new LampError({
      code: "LLM_ERROR",
      message: "Replay model response queue was exhausted",
      safeMessage: "回放记录缺少模型响应。",
    });
    return { ...response, provider: this.name };
  }
}

export class ReplayRunner {
  async replay(rawBundle: unknown, target: ReplayTarget): Promise<ReplayResult> {
    const bundle = ReplayBundleSchema.parse(rawBundle);
    const execution = await target.execute(bundle, new ReplayProvider(bundle.modelResponses));
    const actualHash = hashValue(comparable(execution.response));
    return {
      replayId: bundle.replayId,
      matched: actualHash === bundle.expectedHash,
      expectedHash: bundle.expectedHash,
      actualHash,
      response: execution.response,
    };
  }
}

function comparable(response: AgentResponse): z.infer<typeof ComparableResponseSchema> {
  const { runId: _runId, ...value } = AgentResponseSchema.parse(response);
  return ComparableResponseSchema.parse(value);
}

function hashValue(value: unknown): string {
  return createHash("sha256").update(stableStringify(value)).digest("hex");
}

function stableStringify(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([left], [right]) => left.localeCompare(right))
    .map(([key, item]) => `${JSON.stringify(key)}:${stableStringify(item)}`).join(",")}}`;
  return JSON.stringify(value) ?? "null";
}

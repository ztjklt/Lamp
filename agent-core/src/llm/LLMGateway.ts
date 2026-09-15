import { LampError, toLampError } from "../errors/LampError.js";
import type { Logger } from "../observability/Logger.js";
import type { LLMProvider } from "./LLMProvider.js";
import { LLMRequestSchema, type LLMRequest } from "./LLMRequest.js";
import { LLMResponseSchema, type LLMResponse } from "./LLMResponse.js";

export interface LLMGatewayContext {
  traceId: string;
  runId: string;
}

export class LLMGateway {
  constructor(
    private readonly provider: LLMProvider,
    private readonly logger: Logger,
  ) {}

  async generate(request: LLMRequest, context: LLMGatewayContext): Promise<LLMResponse> {
    const validRequest = LLMRequestSchema.safeParse(request);
    if (!validRequest.success) {
      throw new LampError({
        code: "VALIDATION_ERROR",
        message: "LLM request failed validation",
        safeMessage: "模型请求格式无效。",
        details: { issues: validRequest.error.issues },
      });
    }

    this.logger.info("LLMGateway", "model_call_started", {
      traceId: context.traceId,
      runId: context.runId,
      data: {
        provider: this.provider.name,
        model: validRequest.data.model ?? "provider_default",
        messageCount: validRequest.data.messages.length,
        toolCount: validRequest.data.tools?.length ?? 0,
        thinkingEnabled: validRequest.data.thinking.enabled,
      },
    });

    try {
      const response = await this.provider.generate(validRequest.data);
      const validResponse = LLMResponseSchema.safeParse(response);
      if (!validResponse.success) {
        throw new LampError({
          code: "MODEL_INVALID_OUTPUT",
          message: "LLM provider returned an invalid normalized response",
          safeMessage: "模型返回了无法验证的结果。",
          retryable: true,
          details: { issues: validResponse.error.issues },
        });
      }
      this.logger.info("LLMGateway", "model_call_succeeded", {
        traceId: context.traceId,
        runId: context.runId,
        data: {
          provider: validResponse.data.provider,
          model: validResponse.data.model,
          latencyMs: validResponse.data.latencyMs,
          inputTokens: validResponse.data.usage.inputTokens,
          outputTokens: validResponse.data.usage.outputTokens,
          cacheHitTokens: validResponse.data.usage.cacheHitTokens,
          cacheMissTokens: validResponse.data.usage.cacheMissTokens,
          finishReason: validResponse.data.finishReason,
          toolCallCount: validResponse.data.toolCalls.length,
        },
      });
      return validResponse.data;
    } catch (error) {
      const lampError = toLampError(error);
      this.logger.error("LLMGateway", "model_call_failed", {
        traceId: context.traceId,
        runId: context.runId,
        data: {
          provider: this.provider.name,
          code: lampError.code,
          retryable: lampError.retryable,
        },
      });
      throw lampError;
    }
  }
}

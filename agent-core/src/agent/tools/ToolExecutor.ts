import { z } from "zod";
import { AgentContextSchema } from "../orchestrator/AgentContext.js";
import { StateSnapshotSchema } from "../state/StateSnapshot.js";
import type { Clock } from "../../infrastructure/clock/Clock.js";
import { LampError } from "../../errors/LampError.js";
import type { ErrorCode } from "../../errors/ErrorCode.js";
import type { Logger } from "../../observability/Logger.js";
import type { AuditLog } from "../../observability/AuditLog.js";
import type { ToolCall } from "../schemas/ToolCall.js";
import { UUIDSchema } from "../schemas/Common.js";
import type { RegisteredAgentTool, ToolExecutionContext, ToolRiskLevel } from "./AgentTool.js";
import { ToolResultSchema, type PolicyDecision, type ToolResult } from "./ToolResult.js";
import type { PolicyEngine } from "../policies/PolicyEngine.js";
import type { ToolRegistry } from "./ToolRegistry.js";
import type { ToolValidator } from "./ToolValidator.js";

export class ToolExecutor {
  constructor(
    private readonly registry: ToolRegistry,
    private readonly validator: ToolValidator,
    private readonly policies: PolicyEngine,
    private readonly auditLog: AuditLog,
    private readonly clock: Clock,
    private readonly logger: Logger,
  ) {}

  async execute(rawCall: unknown, context: ToolExecutionContext): Promise<ToolResult> {
    const call = this.validator.validateCall(rawCall);
    this.validateContext(context);
    const startedAt = this.clock.now().toString();
    const tool = this.registry.get(call.name);
    if (!tool) {
      return this.finishFailure(
        call,
        "IRREVERSIBLE",
        startedAt,
        context,
        new LampError({
          code: "TOOL_ERROR",
          message: `Tool is not registered: ${call.name}`,
          safeMessage: "请求的工具不可用。",
        }),
      );
    }
    if (tool.version !== call.version) {
      return this.finishFailure(
        call,
        tool.riskLevel,
        startedAt,
        context,
        new LampError({
          code: "VALIDATION_ERROR",
          message: `Unsupported version ${call.version} for tool ${call.name}`,
          safeMessage: "工具版本不受支持。",
        }),
      );
    }

    let input: unknown;
    try {
      input = this.validator.validateInput(tool, call.arguments);
    } catch (error) {
      return this.finishFailure(call, tool.riskLevel, startedAt, context, asToolError(error));
    }
    context.run?.addToolSelection(call.id, startedAt);

    let decision: PolicyDecision;
    try {
      const evaluation = await this.policies.evaluateDetailed({ tool, input, context });
      decision = evaluation.finalDecision;
      for (const policyDecision of evaluation.decisions) {
        context.run?.addPolicyDecision({
          policyId: policyDecision.policyId,
          decision: policyDecision.decision,
          reasonCode: policyDecision.reasonCode,
          occurredAt: this.clock.now().toString(),
        });
      }
    } catch (error) {
      return this.finishFailure(call, tool.riskLevel, startedAt, context, asPolicyError(error));
    }
    if (decision.decision === "deny") {
      return this.finishWithoutExecution(call, tool, startedAt, context, decision, "denied");
    }
    if (decision.decision === "ask_user") {
      return this.finishWithoutExecution(call, tool, startedAt, context, decision, "confirmation_required");
    }

    this.logger.info("ToolExecutor", "tool_execution_started", {
      traceId: context.traceId,
      runId: context.runId,
      data: { toolName: tool.name, toolVersion: tool.version, riskLevel: tool.riskLevel },
    });
    try {
      await tool.checkPreconditions(input, context);
      const rawOutput = await tool.execute(input, context);
      const output = this.validator.validateOutput(tool, rawOutput);
      if (!output || typeof output !== "object" || Array.isArray(output)) {
        throw new LampError({
          code: "TOOL_ERROR",
          message: `Tool ${tool.name} output must be a JSON object`,
        });
      }
      const result = ToolResultSchema.parse({
        callId: call.id,
        toolName: call.name,
        status: "succeeded",
        output,
        policyDecision: decision,
      });
      await this.auditLog.write({
        callId: call.id,
        userId: context.agent.userId,
        runId: context.runId,
        traceId: context.traceId,
        toolName: tool.name,
        toolVersion: tool.version,
        riskLevel: tool.riskLevel,
        input,
        status: "succeeded",
        policyDecision: decision,
        output,
      });
      this.recordToolCall(call, tool.riskLevel, startedAt, context, "succeeded", output);
      this.logger.info("ToolExecutor", "tool_execution_succeeded", {
        traceId: context.traceId,
        runId: context.runId,
        data: { toolName: tool.name },
      });
      return result;
    } catch (error) {
      return this.finishFailure(call, tool.riskLevel, startedAt, context, asToolError(error), decision);
    }
  }

  private validateContext(context: ToolExecutionContext): void {
    const agent = AgentContextSchema.safeParse(context.agent);
    const state = StateSnapshotSchema.safeParse(context.state);
    const identifiers = z.object({ runId: UUIDSchema, traceId: UUIDSchema }).safeParse(context);
    if (!agent.success || !state.success || !identifiers.success) {
      throw new LampError({
        code: "AUTH_ERROR",
        message: "Tool execution context failed validation",
        safeMessage: "工具执行上下文无效。",
        statusCode: 403,
      });
    }
    if (agent.data.userId !== state.data.userId || context.run?.id && context.run.id !== context.runId ||
        context.run?.traceId && context.run.traceId !== context.traceId) {
      throw new LampError({
        code: "AUTH_ERROR",
        message: "Tool execution context identity mismatch",
        safeMessage: "工具执行身份校验失败。",
        statusCode: 403,
      });
    }
  }

  private async finishWithoutExecution(
    call: ToolCall,
    tool: RegisteredAgentTool,
    startedAt: string,
    context: ToolExecutionContext,
    decision: PolicyDecision,
    status: "denied" | "confirmation_required",
  ): Promise<ToolResult> {
    await this.auditLog.write({
      callId: call.id,
      userId: context.agent.userId,
      runId: context.runId,
      traceId: context.traceId,
      toolName: tool.name,
      toolVersion: tool.version,
      riskLevel: tool.riskLevel,
      input: call.arguments,
      status,
      policyDecision: decision,
    });
    this.recordToolCall(
      call,
      tool.riskLevel,
      startedAt,
      context,
      status === "denied" ? "denied" : "confirmation_required",
    );
    return ToolResultSchema.parse({
      callId: call.id,
      toolName: call.name,
      status,
      policyDecision: decision,
    });
  }

  private async finishFailure(
    call: ToolCall,
    riskLevel: ToolRiskLevel,
    startedAt: string,
    context: ToolExecutionContext,
    error: LampError,
    policyDecision?: PolicyDecision,
  ): Promise<ToolResult> {
    await this.auditLog.write({
      callId: call.id,
      userId: context.agent.userId,
      runId: context.runId,
      traceId: context.traceId,
      toolName: call.name,
      toolVersion: call.version,
      riskLevel,
      input: call.arguments,
      status: "failed",
      ...(policyDecision === undefined ? {} : { policyDecision }),
      errorCode: error.code,
    });
    this.recordToolCall(call, riskLevel, startedAt, context, "failed", undefined, error.code);
    this.logger.error("ToolExecutor", "tool_execution_failed", {
      traceId: context.traceId,
      runId: context.runId,
      data: { toolName: call.name, code: error.code, retryable: error.retryable },
    });
    return ToolResultSchema.parse({
      callId: call.id,
      toolName: call.name,
      status: "failed",
      ...(policyDecision === undefined ? {} : { policyDecision }),
      error: { code: error.code, message: error.safeMessage, retryable: error.retryable },
    });
  }

  private recordToolCall(
    call: ToolCall,
    riskLevel: ToolRiskLevel,
    startedAt: string,
    context: ToolExecutionContext,
    status: "succeeded" | "failed" | "denied" | "confirmation_required",
    output?: unknown,
    errorCode?: ErrorCode,
  ): void {
    if (!context.run) return;
    const result = output && typeof output === "object" && !Array.isArray(output)
      ? output as Record<string, unknown>
      : undefined;
    context.run.addToolCall({
      call,
      riskLevel,
      startedAt,
      endedAt: this.clock.now().toString(),
      status,
      ...(result === undefined ? {} : { result }),
      ...(errorCode === undefined ? {} : { errorCode }),
    });
  }
}

function asToolError(error: unknown): LampError {
  if (error instanceof LampError) return error;
  return new LampError({
    code: "TOOL_ERROR",
    message: error instanceof Error ? error.message : "Unknown tool error",
    safeMessage: "工具执行失败。",
    retryable: false,
    cause: error,
  });
}

function asPolicyError(error: unknown): LampError {
  if (error instanceof LampError) return error;
  return new LampError({
    code: "INTERNAL_ERROR",
    message: error instanceof Error ? error.message : "Unknown policy error",
    safeMessage: "策略检查暂时无法完成。",
    retryable: false,
    cause: error,
  });
}

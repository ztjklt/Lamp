import { LampError } from "../../errors/LampError.js";
import { ToolCallSchema, type ToolCall } from "../schemas/ToolCall.js";
import type { RegisteredAgentTool } from "./AgentTool.js";

export class ToolValidator {
  validateCall(value: unknown): ToolCall {
    const parsed = ToolCallSchema.safeParse(value);
    if (!parsed.success) {
      throw new LampError({
        code: "VALIDATION_ERROR",
        message: "Tool call envelope failed validation",
        safeMessage: "工具请求格式无效。",
        details: { issues: parsed.error.issues },
      });
    }
    return parsed.data;
  }

  validateInput(tool: RegisteredAgentTool, input: unknown): unknown {
    const parsed = tool.inputSchema.safeParse(input);
    if (!parsed.success) {
      throw new LampError({
        code: "VALIDATION_ERROR",
        message: `Input validation failed for tool ${tool.name}`,
        safeMessage: "工具参数未通过校验。",
        details: { toolName: tool.name, issues: parsed.error.issues },
      });
    }
    return parsed.data;
  }

  validateOutput(tool: RegisteredAgentTool, output: unknown): unknown {
    const parsed = tool.outputSchema.safeParse(output);
    if (!parsed.success) {
      throw new LampError({
        code: "TOOL_ERROR",
        message: `Output validation failed for tool ${tool.name}`,
        safeMessage: "工具返回了无效结果。",
        retryable: false,
        details: { toolName: tool.name, issues: parsed.error.issues },
      });
    }
    return parsed.data;
  }
}

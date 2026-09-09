import { LampError } from "../../errors/LampError.js";
import type { RegisteredAgentTool } from "./AgentTool.js";

export class ToolRegistry {
  private readonly tools = new Map<string, RegisteredAgentTool>();

  register(tool: RegisteredAgentTool): void {
    if (!/^[a-z][a-z0-9_]{1,79}$/.test(tool.name)) {
      throw new LampError({
        code: "VALIDATION_ERROR",
        message: `Invalid tool name: ${tool.name}`,
      });
    }
    if (!Number.isInteger(tool.version) || tool.version < 1) {
      throw new LampError({
        code: "VALIDATION_ERROR",
        message: `Invalid version for tool ${tool.name}`,
      });
    }
    if (this.tools.has(tool.name)) {
      throw new LampError({
        code: "CONFLICT_ERROR",
        message: `Tool already registered: ${tool.name}`,
      });
    }
    this.tools.set(tool.name, tool);
  }

  get(name: string): RegisteredAgentTool | undefined {
    return this.tools.get(name);
  }

  list(): ReadonlyArray<RegisteredAgentTool> {
    return [...this.tools.values()].sort((left, right) => left.name.localeCompare(right.name));
  }
}

import { z } from "zod";
import { LampError } from "../errors/LampError.js";

const IntegerFromStringSchema = (minimum: number, maximum: number) =>
  z.coerce.number().int().min(minimum).max(maximum);
const BooleanFromStringSchema = z.union([
  z.boolean(),
  z.enum(["true", "false"]).transform((value) => value === "true"),
]);

const ConfigSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  PORT: IntegerFromStringSchema(1, 65_535).default(8_787),
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
  DEEPSEEK_API_KEY: z.string().trim().min(1).optional(),
  DEEPSEEK_BASE_URL: z.url().default("https://api.deepseek.com"),
  DEFAULT_MODEL: z.string().trim().min(1).default("deepseek-v4-flash"),
  COMPLEX_MODEL: z.string().trim().min(1).default("deepseek-v4-pro"),
  LLM_TIMEOUT_MS: IntegerFromStringSchema(1_000, 120_000).default(20_000),
  AGENT_MAX_TURNS: IntegerFromStringSchema(1, 32).default(8),
  AGENT_MAX_TOOL_CALLS: IntegerFromStringSchema(0, 100).default(20),
  AGENT_MAX_PLANNING_ATTEMPTS: IntegerFromStringSchema(1, 10).default(3),
  AGENT_MAX_REPAIR_ATTEMPTS: IntegerFromStringSchema(0, 10).default(2),
  AGENT_TIMEOUT_MS: IntegerFromStringSchema(1_000, 600_000).default(60_000),
  PLANNING_HORIZON_DAYS: IntegerFromStringSchema(1, 90).default(14),
  ENABLE_DEBUG_ENDPOINTS: BooleanFromStringSchema.default(false),
  ENABLE_MEMORY: BooleanFromStringSchema.default(true),
  ENABLE_AUTO_REPLAN: BooleanFromStringSchema.default(true),
  ENABLE_PRO_MODEL: BooleanFromStringSchema.default(true),
  ENABLE_AUTO_COMMIT: BooleanFromStringSchema.default(false),
}).superRefine((config, context) => {
  if (config.NODE_ENV === "production" && config.DEEPSEEK_API_KEY === undefined) {
    context.addIssue({
      code: "custom",
      path: ["DEEPSEEK_API_KEY"],
      message: "DEEPSEEK_API_KEY is required in production",
    });
  }
  if (config.NODE_ENV === "production" && config.ENABLE_DEBUG_ENDPOINTS) {
    context.addIssue({
      code: "custom",
      path: ["ENABLE_DEBUG_ENDPOINTS"],
      message: "Debug endpoints cannot be enabled in production",
    });
  }
});

export interface AgentConfig {
  environment: "development" | "test" | "production";
  port: number;
  logLevel: "debug" | "info" | "warn" | "error";
  deepSeek: {
    apiKey?: string;
    baseUrl: string;
    defaultModel: string;
    complexModel: string;
    timeoutMs: number;
  };
  limits: {
    maxModelTurns: number;
    maxToolCalls: number;
    maxPlanningAttempts: number;
    maxRepairAttempts: number;
    maxRunDurationMs: number;
  };
  planning: {
    horizonDays: number;
  };
  debug: {
    enabled: boolean;
  };
  features: {
    memory: boolean;
    autoReplan: boolean;
    proModel: boolean;
    autoCommit: boolean;
  };
}

export function loadConfig(environment: NodeJS.ProcessEnv = process.env): AgentConfig {
  const result = ConfigSchema.safeParse(environment);
  if (!result.success) {
    throw new LampError({
      code: "VALIDATION_ERROR",
      message: "Invalid agent configuration",
      safeMessage: "Agent 服务配置无效。",
      details: { issues: result.error.issues },
    });
  }

  const value = result.data;
  const deepSeek = {
    baseUrl: value.DEEPSEEK_BASE_URL.replace(/\/$/, ""),
    defaultModel: value.DEFAULT_MODEL,
    complexModel: value.COMPLEX_MODEL,
    timeoutMs: value.LLM_TIMEOUT_MS,
    ...(value.DEEPSEEK_API_KEY === undefined ? {} : { apiKey: value.DEEPSEEK_API_KEY }),
  };
  return {
    environment: value.NODE_ENV,
    port: value.PORT,
    logLevel: value.LOG_LEVEL,
    deepSeek,
    limits: {
      maxModelTurns: value.AGENT_MAX_TURNS,
      maxToolCalls: value.AGENT_MAX_TOOL_CALLS,
      maxPlanningAttempts: value.AGENT_MAX_PLANNING_ATTEMPTS,
      maxRepairAttempts: value.AGENT_MAX_REPAIR_ATTEMPTS,
      maxRunDurationMs: value.AGENT_TIMEOUT_MS,
    },
    planning: {
      horizonDays: value.PLANNING_HORIZON_DAYS,
    },
    debug: { enabled: value.ENABLE_DEBUG_ENDPOINTS },
    features: {
      memory: value.ENABLE_MEMORY,
      autoReplan: value.ENABLE_AUTO_REPLAN,
      proModel: value.ENABLE_PRO_MODEL,
      autoCommit: value.ENABLE_AUTO_COMMIT,
    },
  };
}

import { z } from "zod";
import { LampError } from "../errors/LampError.js";

const IntegerFromStringSchema = (minimum: number, maximum: number) =>
  z.coerce.number().int().min(minimum).max(maximum);
const BooleanFromStringSchema = z.union([
  z.boolean(),
  z.enum(["true", "false"]).transform((value) => value === "true"),
]);

const ConfigSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "staging", "production"]).default("development"),
  PORT: IntegerFromStringSchema(1, 65_535).default(8_787),
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
  DEEPSEEK_API_KEY: z.string().trim().min(1).optional(),
  SUPABASE_URL: z.url().optional(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().trim().min(20).optional(),
  CONFIRMATION_HMAC_SECRET: z.string().trim().min(32).optional(),
  AGENT_CORE_SERVICE_TOKEN: z.string().trim().min(32).optional(),
  DEEPSEEK_BASE_URL: z.url().default("https://api.deepseek.com"),
  DEFAULT_MODEL: z.string().trim().min(1).default("deepseek-v4-flash"),
  COMPLEX_MODEL: z.string().trim().min(1).default("deepseek-v4-pro"),
  ALLOWED_DEEPSEEK_MODELS: z.string().trim().min(1).default("deepseek-v4-flash,deepseek-v4-pro"),
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
  if (["staging", "production"].includes(config.NODE_ENV) && config.DEEPSEEK_API_KEY === undefined) {
    context.addIssue({
      code: "custom",
      path: ["DEEPSEEK_API_KEY"],
      message: "DEEPSEEK_API_KEY is required in production",
    });
  }
  if (["staging", "production"].includes(config.NODE_ENV) &&
      (config.SUPABASE_URL === undefined || config.SUPABASE_SERVICE_ROLE_KEY === undefined ||
       config.CONFIRMATION_HMAC_SECRET === undefined)) {
    context.addIssue({
      code: "custom",
      path: ["SUPABASE_URL"],
      message: "Supabase URL, service role key, and confirmation secret are required outside local environments",
    });
  }
  if (["staging", "production"].includes(config.NODE_ENV) && config.AGENT_CORE_SERVICE_TOKEN === undefined) {
    context.addIssue({ code: "custom", path: ["AGENT_CORE_SERVICE_TOKEN"], message: "Edge-to-Core service token is required" });
  }
  const allowedModels = new Set(config.ALLOWED_DEEPSEEK_MODELS.split(",").map((model) => model.trim()).filter(Boolean));
  if (!allowedModels.has(config.DEFAULT_MODEL) || !allowedModels.has(config.COMPLEX_MODEL)) {
    context.addIssue({ code: "custom", path: ["ALLOWED_DEEPSEEK_MODELS"], message: "configured model is not allowlisted" });
  }
  if (config.NODE_ENV === "production" && config.ENABLE_DEBUG_ENDPOINTS) {
    context.addIssue({
      code: "custom",
      path: ["ENABLE_DEBUG_ENDPOINTS"],
      message: "Debug endpoints cannot be enabled in production",
    });
  }
  if (["staging", "production"].includes(config.NODE_ENV) && config.ENABLE_AUTO_COMMIT) {
    context.addIssue({
      code: "custom",
      path: ["ENABLE_AUTO_COMMIT"],
      message: "automatic commit is forbidden in staging and production",
    });
  }
});

export interface AgentConfig {
  environment: "development" | "test" | "staging" | "production";
  port: number;
  logLevel: "debug" | "info" | "warn" | "error";
  deepSeek: {
    apiKey?: string;
    baseUrl: string;
    defaultModel: string;
    complexModel: string;
    timeoutMs: number;
  };
  persistence?: {
    supabaseUrl: string;
    serviceRoleKey: string;
    confirmationHmacSecret: string;
  };
  serviceToken?: string;
  allowedModels: readonly string[];
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
  const persistence = value.SUPABASE_URL === undefined || value.SUPABASE_SERVICE_ROLE_KEY === undefined ||
    value.CONFIRMATION_HMAC_SECRET === undefined ? undefined : {
      supabaseUrl: value.SUPABASE_URL.replace(/\/$/, ""),
      serviceRoleKey: value.SUPABASE_SERVICE_ROLE_KEY,
    confirmationHmacSecret: value.CONFIRMATION_HMAC_SECRET,
  };
  const allowedModels = value.ALLOWED_DEEPSEEK_MODELS.split(",").map((model) => model.trim()).filter(Boolean);
  return {
    environment: value.NODE_ENV,
    port: value.PORT,
    logLevel: value.LOG_LEVEL,
    deepSeek,
    ...(persistence === undefined ? {} : { persistence }),
    ...(value.AGENT_CORE_SERVICE_TOKEN === undefined ? {} : { serviceToken: value.AGENT_CORE_SERVICE_TOKEN }),
    allowedModels,
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

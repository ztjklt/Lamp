import http from "node:http";
import { createHash, randomUUID } from "node:crypto";
import { ZodError } from "zod";
import { loadConfig } from "../config/Config.js";
import { LampError } from "../errors/LampError.js";
import { DeepSeekProvider } from "../llm/DeepSeekProvider.js";
import { IdempotencyConflictError, IncompleteReplanService } from "./IncompleteReplanService.js";
import {
  InvalidLanguageDecisionError,
  LanguageReplanService,
  LocalLanguageDecisionProvider,
} from "./LanguageReplanService.js";
import { PlanDayService } from "./PlanDayService.js";
import { V2ProposalService } from "./V2ProposalService.js";
import { InMemoryProposalRepository } from "../infrastructure/repositories/InMemoryProposalRepository.js";
import { SupabaseProposalRepository } from "../infrastructure/repositories/SupabaseProposalRepository.js";
import { InMemoryAgentRunRepository } from "../infrastructure/repositories/InMemoryAgentRunRepository.js";
import { SupabaseAgentRunRepository } from "../infrastructure/repositories/SupabaseRepositories.js";
import { SupabaseRestClient } from "../infrastructure/supabase/SupabaseRestClient.js";

const config = loadConfig({
  ...process.env,
  PORT: process.env["LAMP_AGENT_PORT"] ?? process.env["PORT"],
  AGENT_CORE_SERVICE_TOKEN: process.env["AGENT_CORE_SERVICE_TOKEN"] ?? process.env["LAMP_AGENT_API_TOKEN"],
});
const host = process.env["LAMP_AGENT_HOST"] ?? "0.0.0.0";
const port = config.port;
const serviceToken = config.serviceToken;
const remoteEnvironment = ["staging", "production"].includes(config.environment);
const planDayService = new PlanDayService();
const incompleteReplanService = new IncompleteReplanService();
const languageReplanService = createLanguageReplanService();
const proposalRepository = createProposalRepository();
const runRepository = createAgentRunRepository();
const confirmationSecret = config.persistence?.confirmationHmacSecret ?? "lamp-local-confirmation-secret-32-bytes";
const v2ProposalService = new V2ProposalService(proposalRepository, {
  plan_day: (input) => planDayService.createProposal(input) as unknown as Record<string, unknown>,
  replan_incomplete: async (input, userId) => await incompleteReplanService.createProposal(input, userId) as unknown as Record<string, unknown>,
  replan_language: async (input, userId) => {
    if (languageReplanService === null) throw new LampError({ code: "LLM_ERROR", message: "model not configured", safeMessage: "模型服务尚未配置。", statusCode: 503 });
    return await languageReplanService.createProposal(input, userId) as unknown as Record<string, unknown>;
  },
}, confirmationSecret, () => new Date(), runRepository);

function createProposalRepository() {
  if (config.persistence !== undefined) {
    return new SupabaseProposalRepository(new SupabaseRestClient({
      baseUrl: config.persistence.supabaseUrl,
      serviceRoleKey: config.persistence.serviceRoleKey,
    }));
  }
  if (remoteEnvironment) throw new Error("Supabase production persistence is not configured");
  return new InMemoryProposalRepository();
}

function createAgentRunRepository() {
  if (config.persistence !== undefined) {
    return new SupabaseAgentRunRepository(new SupabaseRestClient({
      baseUrl: config.persistence.supabaseUrl,
      serviceRoleKey: config.persistence.serviceRoleKey,
    }));
  }
  if (remoteEnvironment) throw new Error("Supabase production persistence is not configured");
  return new InMemoryAgentRunRepository();
}

function createLanguageReplanService(): LanguageReplanService | null {
  const apiKey = config.deepSeek.apiKey;
  const model = config.deepSeek.defaultModel;
  if (apiKey !== undefined && apiKey.length > 0) {
    return new LanguageReplanService(new DeepSeekProvider({
      apiKey,
      defaultModel: model,
      timeoutMs: config.deepSeek.timeoutMs,
      baseUrl: config.deepSeek.baseUrl,
    }), { model });
  }
  if (remoteEnvironment) return null;
  return new LanguageReplanService(new LocalLanguageDecisionProvider(), { model: "local-language-fixture" });
}

function send(response: http.ServerResponse, status: number, payload: unknown): void {
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  });
  response.end(JSON.stringify(payload));
}

function readJSON(request: http.IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk: string) => {
      body += chunk;
      if (body.length > 1_000_000) reject(new Error("request_too_large"));
    });
    request.on("end", () => {
      try { resolve(JSON.parse(body)); } catch { reject(new Error("invalid_json")); }
    });
    request.on("error", reject);
  });
}

const server = http.createServer(async (request, response) => {
  const startedAt = performance.now();
  const traceId = safeTraceId(request.headers["x-request-id"]?.toString());
  if (request.method === "GET" && request.url === "/health") {
    send(response, 200, { ok: true, service: "lamp-agent-core", contractVersion: 2 });
    return;
  }
  if (request.method === "GET" && request.url === "/ready") {
    send(response, 200, { ready: true, environment: config.environment, persistence: config.persistence === undefined ? "memory" : "supabase" });
    return;
  }
  const requestURL = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
  const v2CreateMatch = requestURL.pathname.match(/^\/v2\/proposals\/(plan-day|replan-incomplete|replan-language)$/);
  const v2ResourceMatch = requestURL.pathname.match(/^\/v2\/proposals\/([0-9a-f-]+)(?:\/(confirm|reject))?$/i);
  if (v2CreateMatch !== null || v2ResourceMatch !== null) {
    if (serviceToken !== undefined && request.headers.authorization !== `Bearer ${serviceToken}`) {
      send(response, 401, { error: "unauthorized" });
      return;
    }
    const suppliedUser = request.headers["x-lamp-user"]?.toString();
    if (remoteEnvironment && !isUUID(suppliedUser)) {
      send(response, 401, { error: "invalid_user_identity" });
      return;
    }
    const userId = suppliedUser ?? "lamp-local-client";
    try {
      let result: Record<string, unknown>;
      if (v2CreateMatch !== null && request.method === "POST") {
        const kind = v2CreateMatch[1]!.replaceAll("-", "_");
        result = await v2ProposalService.create(kind, await readJSON(request), userId);
      } else if (v2ResourceMatch !== null && request.method === "GET" && v2ResourceMatch[2] === undefined) {
        result = await v2ProposalService.get(v2ResourceMatch[1]!, userId);
      } else if (v2ResourceMatch !== null && request.method === "POST" && v2ResourceMatch[2] === "confirm") {
        result = await v2ProposalService.confirm(v2ResourceMatch[1]!, await readJSON(request), userId);
      } else if (v2ResourceMatch !== null && request.method === "POST" && v2ResourceMatch[2] === "reject") {
        result = await v2ProposalService.reject(v2ResourceMatch[1]!, userId);
      } else {
        send(response, 405, { error: "method_not_allowed" });
        return;
      }
      const metadata = traceMetadata(result["trace"]);
      writeRequestLog({ traceId, userId, route: requestURL.pathname, status: result["status"] ?? "ok",
        latencyMs: performance.now() - startedAt, ...metadata });
      send(response, 200, result);
    } catch (error) {
      sendError(response, "v2_proposal", error, { traceId, userId, route: requestURL.pathname, startedAt });
    }
    return;
  }
  const operation = request.method === "POST" && request.url === "/v1/plan-day"
    ? "plan_day"
    : request.method === "POST" && request.url === "/v1/replan-incomplete"
      ? "replan_incomplete"
      : request.method === "POST" && request.url === "/v1/replan-language"
        ? "replan_language"
      : null;
  if (operation === null) {
    send(response, 404, { error: "not_found" });
    return;
  }
  if (serviceToken !== undefined && request.headers.authorization !== `Bearer ${serviceToken}`) {
    send(response, 401, { error: "unauthorized" });
    return;
  }
  const suppliedUser = request.headers["x-lamp-user"]?.toString();
  if (remoteEnvironment && !isUUID(suppliedUser)) {
    send(response, 401, { error: "invalid_user_identity" });
    return;
  }
  const userId = suppliedUser ?? "lamp-local-client";
  if (operation === "replan_language" && languageReplanService === null) {
    send(response, 503, { error: "model_not_configured" });
    return;
  }
  try {
    const input = await readJSON(request);
    const result = operation === "plan_day"
      ? planDayService.createProposal(input)
      : operation === "replan_incomplete"
        ? await incompleteReplanService.createProposal(input, userId)
        : await languageReplanService!.createProposal(input, userId);
    const correlationId = "requestId" in result ? result.requestId : result.eventId;
    writeRequestLog({ traceId, userId, route: requestURL.pathname,
      status: result.status, latencyMs: performance.now() - startedAt, correlationId });
    send(response, 200, result);
  } catch (error) {
    sendError(response, operation, error, { traceId, userId, route: requestURL.pathname, startedAt });
  }
});

function sendError(
  response: http.ServerResponse,
  operation: string,
  error: unknown,
  context: { traceId: string; userId: string; route: string; startedAt: number },
): void {
  const common = {
    severity: "ERROR",
    event: `${operation}_rejected`,
    traceId: context.traceId,
    userHash: createHash("sha256").update(context.userId).digest("hex").slice(0, 24),
    route: context.route,
    latencyMs: Math.max(0, Math.round(performance.now() - context.startedAt)),
  };
  if (error instanceof ZodError) {
    process.stderr.write(`${JSON.stringify({ ...common, errorCode: "VALIDATION_ERROR", issues: error.issues.map((issue) => issue.path.join(".")) })}\n`);
    send(response, 400, { error: "invalid_request", issues: error.issues.map((issue) => ({ path: issue.path.join("."), message: issue.message })) });
  } else if (error instanceof IdempotencyConflictError) {
    process.stderr.write(`${JSON.stringify({ ...common, errorCode: "CONFLICT_ERROR" })}\n`);
    send(response, 409, { error: error.message });
  } else if (error instanceof InvalidLanguageDecisionError) {
    process.stderr.write(`${JSON.stringify({ ...common, errorCode: "MODEL_INVALID_OUTPUT" })}\n`);
    send(response, 422, { error: "invalid_model_decision", message: "模型没有生成可验证的调整决策。" });
  } else if (error instanceof Error && ["request_too_large", "invalid_json"].includes(error.message)) {
    process.stderr.write(`${JSON.stringify({ ...common, errorCode: "VALIDATION_ERROR" })}\n`);
    send(response, 400, { error: error.message });
  } else if (error instanceof LampError) {
    process.stderr.write(`${JSON.stringify({ ...common, event: `${operation}_failed`, errorCode: error.code })}\n`);
    send(response, error.statusCode, { error: error.code.toLowerCase(), message: error.safeMessage, retryable: error.retryable });
  } else {
    process.stderr.write(`${JSON.stringify({ ...common, event: `${operation}_failed`, errorCode: "INTERNAL_ERROR" })}\n`);
    send(response, 500, { error: "internal_error" });
  }
}

server.listen(port, host, () => {
  process.stdout.write(`Lamp Agent Core API listening on http://${host}:${port}\n`);
});

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => server.close(() => process.exit(0)));
}

function safeTraceId(value: string | undefined): string {
  return value !== undefined && /^[A-Za-z0-9._:-]{1,128}$/.test(value) ? value : randomUUID();
}

function isUUID(value: string | undefined): value is string {
  return value !== undefined && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function writeRequestLog(input: {
  traceId: string; userId?: string; route: string; status: unknown; latencyMs: number; correlationId?: string;
  model?: string; inputTokens?: number; outputTokens?: number; plannerResult?: string; policyResult?: string;
}): void {
  process.stdout.write(`${JSON.stringify({
    severity: "INFO", event: "request_completed", traceId: input.traceId,
    userHash: input.userId === undefined ? undefined : createHash("sha256").update(input.userId).digest("hex").slice(0, 24),
    route: input.route, status: input.status, latencyMs: Math.max(0, Math.round(input.latencyMs)),
    model: input.model, inputTokens: input.inputTokens, outputTokens: input.outputTokens,
    plannerResult: input.plannerResult, policyResult: input.policyResult ?? "proposal_only",
    ...(input.correlationId === undefined ? {} : { correlationId: input.correlationId }),
  })}\n`);
}

function traceMetadata(value: unknown): {
  model?: string; inputTokens?: number; outputTokens?: number; plannerResult?: string;
} {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return {};
  const trace = value as Record<string, unknown>;
  const model = trace["model"];
  const usage = trace["usage"];
  return {
    ...(model !== null && typeof model === "object" && !Array.isArray(model) &&
      typeof (model as Record<string, unknown>)["model"] === "string"
      ? { model: (model as Record<string, unknown>)["model"] as string } : {}),
    ...(usage !== null && typeof usage === "object" && !Array.isArray(usage) &&
      typeof (usage as Record<string, unknown>)["inputTokens"] === "number"
      ? { inputTokens: (usage as Record<string, unknown>)["inputTokens"] as number } : {}),
    ...(usage !== null && typeof usage === "object" && !Array.isArray(usage) &&
      typeof (usage as Record<string, unknown>)["outputTokens"] === "number"
      ? { outputTokens: (usage as Record<string, unknown>)["outputTokens"] as number } : {}),
    ...(Array.isArray(trace["diagnostics"])
      ? { plannerResult: (trace["diagnostics"] as unknown[]).length === 0 ? "feasible" : "diagnostic" } : {}),
  };
}

import http from "node:http";
import { ZodError } from "zod";
import { LampError } from "../errors/LampError.js";
import { DeepSeekProvider } from "../llm/DeepSeekProvider.js";
import { IdempotencyConflictError, IncompleteReplanService } from "./IncompleteReplanService.js";
import {
  InvalidLanguageDecisionError,
  LanguageReplanService,
  LocalLanguageDecisionProvider,
} from "./LanguageReplanService.js";
import { PlanDayService } from "./PlanDayService.js";

const host = process.env["LAMP_AGENT_HOST"] ?? "127.0.0.1";
const port = Number(process.env["LAMP_AGENT_PORT"] ?? 8790);
const serviceToken = process.env["LAMP_AGENT_API_TOKEN"];
const planDayService = new PlanDayService();
const incompleteReplanService = new IncompleteReplanService();
const languageReplanService = createLanguageReplanService();

function createLanguageReplanService(): LanguageReplanService | null {
  const apiKey = process.env["DEEPSEEK_API_KEY"]?.trim();
  const model = process.env["DEFAULT_MODEL"]?.trim() || "deepseek-v4-flash";
  if (apiKey !== undefined && apiKey.length > 0) {
    const baseUrl = process.env["DEEPSEEK_BASE_URL"]?.trim();
    const configuredTimeout = Number(process.env["LLM_TIMEOUT_MS"] ?? 20_000);
    return new LanguageReplanService(new DeepSeekProvider({
      apiKey,
      defaultModel: model,
      timeoutMs: Number.isFinite(configuredTimeout) ? configuredTimeout : 20_000,
      ...(baseUrl === undefined || baseUrl.length === 0 ? {} : { baseUrl }),
    }), { model });
  }
  if (process.env["NODE_ENV"] === "production") return null;
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
  if (request.method === "GET" && request.url === "/health") {
    send(response, 200, { ok: true, service: "lamp-agent-core", contractVersion: 1 });
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
  if (operation === "replan_language" && languageReplanService === null) {
    send(response, 503, { error: "model_not_configured" });
    return;
  }
  try {
    const input = await readJSON(request);
    const result = operation === "plan_day"
      ? planDayService.createProposal(input)
      : operation === "replan_incomplete"
        ? await incompleteReplanService.createProposal(input, request.headers["x-lamp-user"]?.toString() ?? "lamp-local-client")
        : await languageReplanService!.createProposal(input, request.headers["x-lamp-user"]?.toString() ?? "lamp-local-client");
    const correlationId = "requestId" in result ? result.requestId : result.eventId;
    process.stdout.write(`${JSON.stringify({ event: operation, correlationId, status: result.status })}\n`);
    send(response, 200, result);
  } catch (error) {
    if (error instanceof ZodError) {
      process.stderr.write(`${JSON.stringify({ event: `${operation}_rejected`, issues: error.issues.map((issue) => issue.path.join(".")) })}\n`);
      send(response, 400, { error: "invalid_request", issues: error.issues.map((issue) => ({ path: issue.path.join("."), message: issue.message })) });
    } else if (error instanceof IdempotencyConflictError) {
      process.stderr.write(`${JSON.stringify({ event: `${operation}_rejected`, reason: error.message })}\n`);
      send(response, 409, { error: error.message });
    } else if (error instanceof InvalidLanguageDecisionError) {
      process.stderr.write(`${JSON.stringify({ event: `${operation}_rejected`, reason: error.message })}\n`);
      send(response, 422, { error: "invalid_model_decision", message: "模型没有生成可验证的调整决策。" });
    } else if (error instanceof Error && ["request_too_large", "invalid_json"].includes(error.message)) {
      process.stderr.write(`${JSON.stringify({ event: `${operation}_rejected`, reason: error.message })}\n`);
      send(response, 400, { error: error.message });
    } else if (error instanceof LampError) {
      process.stderr.write(`${JSON.stringify({ event: `${operation}_failed`, code: error.code })}\n`);
      send(response, error.statusCode, { error: error.code.toLowerCase(), message: error.safeMessage, retryable: error.retryable });
    } else {
      process.stderr.write(`${JSON.stringify({ event: `${operation}_failed` })}\n`);
      send(response, 500, { error: "internal_error" });
    }
  }
});

server.listen(port, host, () => {
  process.stdout.write(`Lamp Agent Core API listening on http://${host}:${port}\n`);
});

import http from "node:http";
import { execFileSync } from "node:child_process";

const host = "127.0.0.1";
const port = Number(process.env.LAMP_AGENT_PORT ?? 8787);
const model = process.env.DEEPSEEK_MODEL ?? "deepseek-v4-flash";
const key = process.env.DEEPSEEK_API_KEY ?? execFileSync(
  "/usr/bin/security",
  ["find-generic-password", "-a", "local-dev", "-s", "com.lamp.deepseek", "-w"],
  { encoding: "utf8" },
).trim();

const tools = [
  {
    type: "function",
    function: {
      name: "create_item",
      description: "Create one ordinary, low-risk flexible planning item.",
      parameters: {
        type: "object",
        properties: {
          title: { type: "string", description: "Concise task or goal title in the user's language." },
          detail: { type: "string", description: "Original useful context, without invented facts." },
          estimated_minutes: { type: "integer", minimum: 20, maximum: 480 },
          deadline_hint: { type: ["string", "null"], description: "Natural-language deadline only when explicitly present." },
        },
        required: ["title", "detail", "estimated_minutes", "deadline_hint"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function",
    function: {
      name: "set_temporary_state",
      description: "Record a temporary state such as fatigue and preview a lighter plan. Never make it a durable trait.",
      parameters: {
        type: "object",
        properties: {
          state: { type: "string", enum: ["fatigue", "illness", "travel", "busy"] },
          note: { type: "string" },
        },
        required: ["state", "note"],
        additionalProperties: false,
      },
    },
  },
  {
    type: "function",
    function: {
      name: "ask_clarification",
      description: "Ask exactly one question only when uncertainty materially changes the plan.",
      parameters: {
        type: "object",
        properties: { question: { type: "string" } },
        required: ["question"],
        additionalProperties: false,
      },
    },
  },
];

const allowed = new Set(tools.map((tool) => tool.function.name));

function json(response, status, payload) {
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Access-Control-Allow-Origin": "*",
  });
  response.end(JSON.stringify(payload));
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > 32_000) reject(new Error("request_too_large"));
    });
    request.on("end", () => resolve(body));
    request.on("error", reject);
  });
}

const server = http.createServer(async (request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    return json(response, 200, { ok: true, model });
  }
  if (request.method !== "POST" || request.url !== "/v1/interpret") {
    return json(response, 404, { error: "not_found" });
  }

  try {
    const parsed = JSON.parse(await readBody(request));
    if (typeof parsed.input !== "string" || parsed.input.trim().length === 0) {
      return json(response, 400, { error: "input_required" });
    }
    const upstream = await fetch("https://api.deepseek.com/chat/completions", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
      body: JSON.stringify({
        model,
        thinking: { type: "disabled" },
        messages: [
          {
            role: "system",
            content: "You are Lamp's intent router. Select exactly one typed tool. Preserve the user's language. Never infer destructive action. Fatigue is temporary. Do not expose reasoning.",
          },
          { role: "user", content: parsed.input },
        ],
        tools,
        tool_choice: "required",
        max_tokens: 500,
      }),
      signal: AbortSignal.timeout(20_000),
    });
    if (!upstream.ok) return json(response, 502, { error: "provider_error", status: upstream.status });
    const result = await upstream.json();
    const call = result.choices?.[0]?.message?.tool_calls?.[0]?.function;
    if (!call || !allowed.has(call.name)) return json(response, 422, { error: "invalid_tool" });
    let args;
    try { args = JSON.parse(call.arguments); } catch { return json(response, 422, { error: "invalid_arguments" }); }
    return json(response, 200, { name: call.name, arguments: args, model });
  } catch (error) {
    return json(response, 500, { error: error?.message ?? "internal_error" });
  }
});

server.listen(port, host, () => {
  console.log(`Lamp local agent proxy listening on http://${host}:${port} (${model})`);
});


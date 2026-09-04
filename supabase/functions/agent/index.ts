import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type Risk = "low" | "medium" | "high";
type LampToolCall = { name: string; version: 1; arguments: Record<string, unknown> };

const TOOL_POLICY: Record<string, Risk> = {
  get_today_schedule: "low",
  create_item: "low",
  record_completion: "low",
  record_partial_completion: "low",
  preview_replan: "medium",
  apply_replan: "medium",
  confirm_memory: "medium",
  delete_item: "high",
};

const model = Deno.env.get("DEEPSEEK_MODEL") ?? "deepseek-v4-flash";
const deepSeekURL = Deno.env.get("DEEPSEEK_BASE_URL") ?? "https://api.deepseek.com";

function validate(call: LampToolCall): { ok: true; risk: Risk } | { ok: false; reason: string } {
  if (call.version !== 1) return { ok: false, reason: "unsupported_tool_version" };
  const risk = TOOL_POLICY[call.name];
  if (!risk) return { ok: false, reason: "tool_not_allowlisted" };
  if (call.name === "create_item" && typeof call.arguments.title !== "string") {
    return { ok: false, reason: "title_required" };
  }
  return { ok: true, risk };
}

Deno.serve(async (request) => {
  const authorization = request.headers.get("Authorization");
  if (!authorization) return Response.json({ error: "unauthorized" }, { status: 401 });

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authorization } } },
  );
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return Response.json({ error: "unauthorized" }, { status: 401 });

  const { input, idempotencyKey, confirmationToken } = await request.json();
  if (typeof input !== "string" || typeof idempotencyKey !== "string") {
    return Response.json({ error: "invalid_request" }, { status: 400 });
  }

  // The model only receives a typed tool catalog. It never receives a database client or credential.
  const aiResponse = await fetch(`${deepSeekURL}/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${Deno.env.get("DEEPSEEK_API_KEY")}` },
    body: JSON.stringify({
      model,
      thinking: { type: "disabled" },
      messages: [
        { role: "system", content: "Translate input into exactly one safe Lamp tool call. Never invent destructive intent." },
        { role: "user", content: input },
      ],
      tools: Object.entries(TOOL_POLICY).map(([name]) => ({
        type: "function",
        function: { name, description: `Lamp domain tool ${name}`, parameters: { type: "object", additionalProperties: true } },
      })),
      tool_choice: "required",
    }),
    signal: AbortSignal.timeout(20_000),
  });
  if (!aiResponse.ok) return Response.json({ error: "provider_unavailable" }, { status: 503 });

  const body = await aiResponse.json();
  const raw = body.choices?.[0]?.message?.tool_calls?.[0]?.function;
  let call: LampToolCall;
  try {
    call = { name: raw.name, version: 1, arguments: JSON.parse(raw.arguments) };
  } catch {
    return Response.json({ error: "invalid_model_tool_call" }, { status: 422 });
  }

  const validation = validate(call);
  if (!validation.ok) return Response.json({ error: validation.reason }, { status: 422 });
  if (validation.risk === "high" && !confirmationToken) {
    return Response.json({ status: "confirmation_required", call, risk: validation.risk }, { status: 409 });
  }

  // Production executors are one function per tool and use database transactions. This skeleton
  // deliberately audits the validated request without exposing generic SQL execution to the model.
  const { error } = await admin.from("agent_actions").insert({
    user_id: user.id,
    idempotency_key: idempotencyKey,
    tool_name: call.name,
    tool_version: call.version,
    model,
    risk: validation.risk,
    validation_result: { ok: true },
    execution_result: { status: "accepted_for_domain_executor" },
  });
  if (error?.code === "23505") return Response.json({ status: "already_processed" });
  if (error) return Response.json({ error: "audit_write_failed" }, { status: 500 });
  return Response.json({ status: "accepted", call, risk: validation.risk });
});

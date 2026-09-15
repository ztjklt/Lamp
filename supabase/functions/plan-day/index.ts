import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return Response.json({ error: "method_not_allowed" }, { status: 405 });
  }
  const authorization = request.headers.get("Authorization");
  if (!authorization) return Response.json({ error: "unauthorized" }, { status: 401 });

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authorization } } },
  );
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return Response.json({ error: "unauthorized" }, { status: 401 });

  const agentCoreURL = Deno.env.get("AGENT_CORE_URL")?.replace(/\/$/, "");
  const serviceToken = Deno.env.get("AGENT_CORE_SERVICE_TOKEN");
  if (!agentCoreURL || !serviceToken) {
    return Response.json({ error: "service_not_configured" }, { status: 503 });
  }

  const body = await request.text();
  if (body.length === 0 || body.length > 1_000_000) {
    return Response.json({ error: "invalid_request_size" }, { status: 400 });
  }
  try {
    JSON.parse(body);
  } catch {
    return Response.json({ error: "invalid_json" }, { status: 400 });
  }

  try {
    const upstream = await fetch(`${agentCoreURL}/v1/plan-day`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${serviceToken}`,
        "X-Lamp-User": user.id,
      },
      body,
      signal: AbortSignal.timeout(25_000),
    });
    const payload = await upstream.text();
    return new Response(payload, {
      status: upstream.status,
      headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
    });
  } catch {
    return Response.json({ error: "agent_core_unavailable" }, { status: 503 });
  }
});


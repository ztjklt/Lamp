import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const jsonHeaders = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" };

Deno.serve(async (request) => {
  const authorization = request.headers.get("Authorization");
  if (!authorization) return Response.json({ error: "unauthorized" }, { status: 401, headers: jsonHeaders });

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authorization } } },
  );
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) return Response.json({ error: "unauthorized" }, { status: 401, headers: jsonHeaders });

  const coreURL = Deno.env.get("AGENT_CORE_URL")?.replace(/\/$/, "");
  const serviceToken = Deno.env.get("AGENT_CORE_SERVICE_TOKEN");
  if (!coreURL || !serviceToken) {
    return Response.json({ error: "service_not_configured" }, { status: 503, headers: jsonHeaders });
  }

  const sourceURL = new URL(request.url);
  const marker = "/proposals";
  const markerIndex = sourceURL.pathname.lastIndexOf(marker);
  const suffix = markerIndex < 0 ? "" : sourceURL.pathname.slice(markerIndex + marker.length);
  if (!/^\/(plan-day|replan-incomplete|replan-language|[0-9a-f-]+(?:\/(?:confirm|reject))?)$/i.test(suffix)) {
    return Response.json({ error: "not_found" }, { status: 404, headers: jsonHeaders });
  }
  const isRead = request.method === "GET" && /^\/[0-9a-f-]+$/i.test(suffix);
  if (!isRead && request.method !== "POST") {
    return Response.json({ error: "method_not_allowed" }, { status: 405, headers: jsonHeaders });
  }

  const body = isRead ? undefined : await request.text();
  if (body !== undefined && (body.length === 0 || body.length > 1_000_000)) {
    return Response.json({ error: "invalid_request_size" }, { status: 400, headers: jsonHeaders });
  }
  if (body !== undefined) {
    try { JSON.parse(body); } catch { return Response.json({ error: "invalid_json" }, { status: 400, headers: jsonHeaders }); }
  }

  const traceId = request.headers.get("X-Request-ID") ?? crypto.randomUUID();
  const timeout = suffix === "/replan-language" ? 12_000 : 5_000;
  try {
    const upstream = await fetch(`${coreURL}/v2/proposals${suffix}`, {
      method: request.method,
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${serviceToken}`,
        "X-Lamp-User": user.id,
        "X-Request-ID": traceId,
      },
      ...(body === undefined ? {} : { body }),
      signal: AbortSignal.timeout(timeout),
    });
    return new Response(await upstream.text(), {
      status: upstream.status,
      headers: { ...jsonHeaders, "X-Request-ID": traceId },
    });
  } catch {
    return Response.json({ error: "agent_core_unavailable", traceId }, { status: 503, headers: jsonHeaders });
  }
});

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" };

Deno.serve(async (request) => {
  if (request.method !== "POST") return Response.json({ error: "method_not_allowed" }, { status: 405, headers });
  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return Response.json({ error: "unauthorized" }, { status: 401, headers });

  const url = new URL(request.url);
  const operation = url.pathname.split("/").filter(Boolean).at(-1);
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const targetToken = authorization.slice("Bearer ".length);
  const { data: { user: targetUser } } = await admin.auth.getUser(targetToken);
  if (!targetUser) return Response.json({ error: "unauthorized" }, { status: 401, headers });

  if (operation === "upgrade") {
    const sourceAuthorization = request.headers.get("X-Source-Authorization");
    if (!sourceAuthorization?.startsWith("Bearer ")) {
      return Response.json({ error: "source_session_required" }, { status: 401, headers });
    }
    const { data: { user: sourceUser } } = await admin.auth.getUser(sourceAuthorization.slice("Bearer ".length));
    if (!sourceUser?.is_anonymous) return Response.json({ error: "anonymous_source_required" }, { status: 403, headers });
    const providers = targetUser.app_metadata?.providers;
    if (!Array.isArray(providers) || !providers.includes("apple")) {
      return Response.json({ error: "apple_identity_required" }, { status: 403, headers });
    }
    const { data, error } = await admin.rpc("migrate_anonymous_account", {
      p_source_user: sourceUser.id, p_target_user: targetUser.id,
    });
    if (error) return Response.json({ error: "account_merge_conflict" }, { status: 409, headers });
    if (sourceUser.id !== targetUser.id) await admin.auth.admin.deleteUser(sourceUser.id, false);
    return Response.json(data, { status: 200, headers });
  }

  if (operation === "export") {
    const tables = [
      "profiles", "plan_nodes", "schedule_blocks", "memories", "replan_proposals",
      "planning_rules", "temporary_states", "recurring_schedule_rules", "schedule_occurrence_overrides",
    ];
    const data: Record<string, unknown> = {};
    for (const table of tables) {
      const query = table === "profiles"
        ? admin.from(table).select("*").eq("id", targetUser.id)
        : admin.from(table).select("*").eq("user_id", targetUser.id);
      const result = await query;
      if (result.error) return Response.json({ error: "export_failed" }, { status: 503, headers });
      data[table] = result.data;
    }
    return Response.json({ schemaVersion: 1, exportedAt: new Date().toISOString(), data }, { status: 200, headers });
  }

  if (operation === "delete") {
    let payload: Record<string, unknown> = {};
    try { payload = await request.json(); } catch { /* handled below */ }
    if (payload.confirmation !== "DELETE") {
      return Response.json({ error: "explicit_confirmation_required" }, { status: 400, headers });
    }
    const bucket = Deno.env.get("USER_CONTENT_BUCKET") ?? "user-content";
    const storageError = await removeStorageTree(admin.storage.from(bucket), targetUser.id);
    if (storageError !== null) {
      return Response.json({ error: "account_storage_deletion_failed" }, { status: 503, headers });
    }
    const { error } = await admin.auth.admin.deleteUser(targetUser.id, false);
    if (error) return Response.json({ error: "account_deletion_failed" }, { status: 503, headers });
    const { data: receipt, error: receiptError } = await admin.rpc("record_account_deletion", { p_user_id: targetUser.id });
    if (receiptError) return Response.json({ error: "deletion_audit_failed" }, { status: 503, headers });
    return Response.json({ status: "completed", receipt }, { status: 200, headers });
  }

  return Response.json({ error: "not_found" }, { status: 404, headers });
});

async function removeStorageTree(
  bucket: ReturnType<ReturnType<typeof createClient>["storage"]["from"]>,
  root: string,
): Promise<unknown | null> {
  const files: string[] = [];
  const directories = [root];
  while (directories.length > 0) {
    const directory = directories.pop()!;
    for (let offset = 0;; offset += 100) {
      const listed = await bucket.list(directory, { limit: 100, offset });
      if (listed.error) return listed.error;
      const entries = listed.data ?? [];
      for (const entry of entries) {
        const path = `${directory}/${entry.name}`;
        if (entry.id === null) directories.push(path);
        else files.push(path);
      }
      if (entries.length < 100) break;
    }
  }
  for (let offset = 0; offset < files.length; offset += 100) {
    const removed = await bucket.remove(files.slice(offset, offset + 100));
    if (removed.error) return removed.error;
  }
  return null;
}

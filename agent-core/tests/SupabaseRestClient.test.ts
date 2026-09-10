import { describe, expect, it, vi } from "vitest";
import { SupabaseRestClient } from "../src/infrastructure/supabase/SupabaseRestClient.js";

function client(response: Response) {
  const request = vi.fn(async () => response);
  return { request, client: new SupabaseRestClient({
    baseUrl: "https://fixture.supabase.co/", serviceRoleKey: "service-role-fixture", fetch: request,
  }) };
}

describe("SupabaseRestClient", () => {
  it("uses only server credentials and normalizes REST requests", async () => {
    const { request, client: api } = client(new Response(JSON.stringify([{ id: "one" }]), { status: 200 }));
    await expect(api.select("agent_runs", "user_id=eq.one")).resolves.toEqual([{ id: "one" }]);
    expect(request).toHaveBeenCalledWith("https://fixture.supabase.co/rest/v1/agent_runs?user_id=eq.one", expect.objectContaining({
      method: "GET", headers: expect.objectContaining({ authorization: "Bearer service-role-fixture" }),
    }));
  });

  it.each([
    ["proposal_expired", "STALE_STATE", 410],
    ["stale_state", "CONFLICT_ERROR", 409],
    ["idempotency_content_mismatch", "CONFLICT_ERROR", 409],
    ["proposal_confirmation_invalid", "AUTH_ERROR", 403],
    ["proposal_not_found", "AUTH_ERROR", 404],
  ] as const)("maps %s to a safe domain error", async (message, code, statusCode) => {
    const { client: api } = client(new Response(JSON.stringify({ code: "P0001", message }), { status: 400 }));
    await expect(api.rpc("confirm_agent_proposal", {})).rejects.toMatchObject({ code, statusCode });
  });

  it("never exposes provider response bodies in the safe message", async () => {
    const { client: api } = client(new Response(JSON.stringify({ message: "private database detail" }), { status: 500 }));
    await expect(api.select("agent_runs", "select=*")).rejects.toMatchObject({
      code: "DATABASE_ERROR", safeMessage: "云端数据服务暂时不可用。",
    });
  });
});

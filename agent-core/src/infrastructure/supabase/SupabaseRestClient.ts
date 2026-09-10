import { LampError } from "../../errors/LampError.js";

export interface SupabaseRestClientOptions {
  baseUrl: string;
  serviceRoleKey: string;
  fetch?: typeof fetch;
}

export class SupabaseRestClient {
  private readonly requestFetch: typeof fetch;
  private readonly baseUrl: string;

  constructor(private readonly options: SupabaseRestClientOptions) {
    this.baseUrl = options.baseUrl.replace(/\/$/, "");
    this.requestFetch = options.fetch ?? fetch;
  }

  async select<T>(table: string, query: string): Promise<T[]> {
    return this.request<T[]>(`/rest/v1/${table}?${query}`, { method: "GET" });
  }

  async insert<T>(table: string, body: unknown, onConflict?: string): Promise<T[]> {
    const query = onConflict === undefined ? "" : `?on_conflict=${encodeURIComponent(onConflict)}`;
    return this.request<T[]>(`/rest/v1/${table}${query}`, {
      method: "POST",
      headers: {
        Prefer: onConflict === undefined
          ? "return=representation"
          : "resolution=merge-duplicates,return=representation",
      },
      body: JSON.stringify(body),
    });
  }

  async update<T>(table: string, query: string, body: unknown): Promise<T[]> {
    return this.request<T[]>(`/rest/v1/${table}?${query}`, {
      method: "PATCH",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify(body),
    });
  }

  async delete<T>(table: string, query: string): Promise<T[]> {
    return this.request<T[]>(`/rest/v1/${table}?${query}`, {
      method: "DELETE",
      headers: { Prefer: "return=representation" },
    });
  }

  async rpc<T>(name: string, body: unknown): Promise<T> {
    return this.request<T>(`/rest/v1/rpc/${name}`, { method: "POST", body: JSON.stringify(body) });
  }

  private async request<T>(path: string, init: RequestInit): Promise<T> {
    let response: Response;
    try {
      response = await this.requestFetch(`${this.baseUrl}${path}`, {
        ...init,
        headers: {
          apikey: this.options.serviceRoleKey,
          authorization: `Bearer ${this.options.serviceRoleKey}`,
          "content-type": "application/json",
          ...(init.headers ?? {}),
        },
      });
    } catch (cause) {
      throw databaseError("Supabase request failed", true, cause);
    }
    const text = await response.text();
    if (!response.ok) {
      throw mapDatabaseError(response.status, text);
    }
    if (text.length === 0) return undefined as T;
    try {
      return JSON.parse(text) as T;
    } catch (cause) {
      throw databaseError("Supabase returned invalid JSON", false, cause);
    }
  }
}

function mapDatabaseError(status: number, text: string): LampError {
  let providerCode = "";
  let providerMessage = "";
  try {
    const body = JSON.parse(text) as Record<string, unknown>;
    providerCode = typeof body["code"] === "string" ? body["code"] : "";
    providerMessage = typeof body["message"] === "string" ? body["message"] : "";
  } catch {
    providerMessage = text.slice(0, 200);
  }
  const marker = `${providerCode}:${providerMessage}`;
  if (marker.includes("proposal_expired")) {
    return new LampError({ code: "STALE_STATE", message: marker, safeMessage: "调整方案已过期，请重新生成。", statusCode: 410 });
  }
  if (/stale_state|version_mismatch|not_pending|idempotency_content_mismatch|23505/.test(marker) || status === 409) {
    return new LampError({ code: "CONFLICT_ERROR", message: marker, safeMessage: "数据状态已变化，请刷新后重试。", statusCode: 409 });
  }
  if (/confirmation_invalid|identity_mismatch|28000|42501/.test(marker) || status === 401 || status === 403) {
    return new LampError({ code: "AUTH_ERROR", message: marker, safeMessage: "无权执行这项操作。", statusCode: status === 401 ? 401 : 403 });
  }
  if (marker.includes("proposal_not_found") || status === 404) {
    return new LampError({ code: "AUTH_ERROR", message: marker, safeMessage: "无法访问该调整方案。", statusCode: 404 });
  }
  return databaseError(`Supabase rejected request with ${status}`, status >= 500, {
    status,
    providerCode,
    providerMessage: providerMessage.slice(0, 500),
  });
}

function databaseError(message: string, retryable: boolean, cause?: unknown): LampError {
  return new LampError({
    code: "DATABASE_ERROR",
    message,
    safeMessage: "云端数据服务暂时不可用。",
    retryable,
    statusCode: 503,
    cause,
  });
}

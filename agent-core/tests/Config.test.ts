import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config/Config.js";
import { LampError } from "../src/errors/LampError.js";

describe("loadConfig", () => {
  it("uses bounded foundation defaults", () => {
    const config = loadConfig({ NODE_ENV: "test" });

    expect(config.deepSeek.defaultModel).toBe("deepseek-v4-flash");
    expect(config.deepSeek.complexModel).toBe("deepseek-v4-pro");
    expect(config.deepSeek.apiKey).toBeUndefined();
    expect(config.limits).toEqual({
      maxModelTurns: 8,
      maxToolCalls: 20,
      maxPlanningAttempts: 3,
      maxRepairAttempts: 2,
      maxRunDurationMs: 60_000,
    });
    expect(config.planning.horizonDays).toBe(14);
    expect(config.debug.enabled).toBe(false);
    expect(config.features).toEqual({ memory: true, autoReplan: true, proModel: true, autoCommit: false });
  });

  it("rejects unsafe limit values", () => {
    expect(() => loadConfig({ AGENT_MAX_TURNS: "0" })).toThrowError(LampError);
  });

  it("normalizes the provider base URL", () => {
    const config = loadConfig({ DEEPSEEK_BASE_URL: "https://api.deepseek.com/" });
    expect(config.deepSeek.baseUrl).toBe("https://api.deepseek.com");
  });

  it("fails closed without a provider key in production", () => {
    expect(() => loadConfig({ NODE_ENV: "production" })).toThrowError(LampError);
  });

  it("never permits debug endpoints in production", () => {
    expect(() => loadConfig({
      NODE_ENV: "production",
      DEEPSEEK_API_KEY: "fixture-key",
      ENABLE_DEBUG_ENDPOINTS: "true",
    })).toThrowError(LampError);
  });
});

import { describe, expect, it } from "vitest";
import { AgentContextSchema } from "../src/agent/orchestrator/AgentContext.js";
import { IntentSchema } from "../src/agent/schemas/Intent.js";

describe("foundation schemas", () => {
  it("binds authenticated identity to the requested user", () => {
    const result = AgentContextSchema.safeParse({
      userId: "user-a",
      sessionId: "session-1",
      requestId: "request-1",
      timezone: "Asia/Singapore",
      locale: "zh-CN",
      automationLevel: 0,
      authentication: { subject: "user-b", scopes: ["agent:run"] },
    });

    expect(result.success).toBe(false);
  });

  it("rejects unknown structured intent fields", () => {
    const result = IntentSchema.safeParse({
      intent: "plan_schedule",
      confidence: 0.9,
      entities: {},
      requiresClarification: false,
      rawSql: "delete from tasks",
    });

    expect(result.success).toBe(false);
  });

  it("compares date ranges as instants rather than ISO strings", () => {
    const result = IntentSchema.safeParse({
      intent: "query_schedule",
      confidence: 1,
      entities: {
        dateRange: {
          start: "2026-09-08T12:00:00+08:00",
          end: "2026-09-08T05:00:00+00:00",
        },
      },
      requiresClarification: false,
    });

    expect(result.success).toBe(true);
  });
});

import { describe, expect, it } from "vitest";
import { StructuredLogger, type LogRecord } from "../src/observability/Logger.js";

describe("StructuredLogger", () => {
  it("writes structured records and recursively redacts secrets", () => {
    const records: LogRecord[] = [];
    const logger = new StructuredLogger(
      "debug",
      () => "2026-09-08T00:00:00.000Z",
      (record) => records.push(record as LogRecord),
    );

    logger.info("LLMGateway", "request", {
      traceId: "trace",
      data: {
        authorization: "Bearer private-token",
        nested: { api_key: "secret", harmless: "Bearer another-token" },
      },
    });

    expect(records).toHaveLength(1);
    expect(records[0]).toMatchObject({
      level: "info",
      component: "LLMGateway",
      event: "request",
      traceId: "trace",
    });
    expect(records[0]?.data).toEqual({
      authorization: "[REDACTED]",
      nested: { api_key: "[REDACTED]", harmless: "Bearer [REDACTED]" },
    });
  });

  it("filters records below the configured level", () => {
    const records: LogRecord[] = [];
    const logger = new StructuredLogger("warn", () => "2026-09-08T00:00:00.000Z", (record) => {
      records.push(record as LogRecord);
    });
    logger.info("test", "hidden");
    logger.warn("test", "visible");
    expect(records.map((record) => record.event)).toEqual(["visible"]);
  });
});

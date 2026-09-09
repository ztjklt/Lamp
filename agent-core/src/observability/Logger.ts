export const LOG_LEVELS = ["debug", "info", "warn", "error"] as const;
export type LogLevel = (typeof LOG_LEVELS)[number];

export interface LogRecord {
  level: LogLevel;
  component: string;
  event: string;
  timestamp: string;
  traceId?: string;
  runId?: string;
  data?: Readonly<Record<string, unknown>>;
}

export interface LogContext {
  traceId?: string;
  runId?: string;
  data?: Readonly<Record<string, unknown>>;
}

export interface Logger {
  debug(component: string, event: string, context?: LogContext): void;
  info(component: string, event: string, context?: LogContext): void;
  warn(component: string, event: string, context?: LogContext): void;
  error(component: string, event: string, context?: LogContext): void;
}

export type LogSink = (record: Readonly<LogRecord>) => void;
export type TimestampSource = () => string;

const SECRET_KEY = /(authorization|api[-_]?key|password|refresh[-_]?token|access[-_]?token|secret)/i;
const BEARER_VALUE = /Bearer\s+[A-Za-z0-9._~+/=-]+/gi;

export function redact(value: unknown, key = ""): unknown {
  if (SECRET_KEY.test(key)) return "[REDACTED]";
  if (typeof value === "string") return value.replace(BEARER_VALUE, "Bearer [REDACTED]");
  if (Array.isArray(value)) return value.map((item) => redact(item));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([entryKey, entryValue]) => [entryKey, redact(entryValue, entryKey)]),
    );
  }
  return value;
}

const severity: Record<LogLevel, number> = { debug: 10, info: 20, warn: 30, error: 40 };

export class StructuredLogger implements Logger {
  constructor(
    private readonly minimumLevel: LogLevel,
    private readonly timestampSource: TimestampSource,
    private readonly sink: LogSink,
  ) {}

  debug(component: string, event: string, context?: LogContext): void {
    this.write("debug", component, event, context);
  }

  info(component: string, event: string, context?: LogContext): void {
    this.write("info", component, event, context);
  }

  warn(component: string, event: string, context?: LogContext): void {
    this.write("warn", component, event, context);
  }

  error(component: string, event: string, context?: LogContext): void {
    this.write("error", component, event, context);
  }

  private write(level: LogLevel, component: string, event: string, context?: LogContext): void {
    if (severity[level] < severity[this.minimumLevel]) return;
    const safeData = context?.data === undefined
      ? undefined
      : redact(context.data) as Readonly<Record<string, unknown>>;
    this.sink({
      level,
      component,
      event,
      timestamp: this.timestampSource(),
      ...(context?.traceId === undefined ? {} : { traceId: context.traceId }),
      ...(context?.runId === undefined ? {} : { runId: context.runId }),
      ...(safeData === undefined ? {} : { data: safeData }),
    });
  }
}

export const nullLogger: Logger = {
  debug: () => undefined,
  info: () => undefined,
  warn: () => undefined,
  error: () => undefined,
};

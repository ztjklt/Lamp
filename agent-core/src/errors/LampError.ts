import type { ErrorCode } from "./ErrorCode.js";

export interface LampErrorOptions {
  code: ErrorCode;
  message: string;
  safeMessage?: string;
  retryable?: boolean;
  statusCode?: number;
  details?: Readonly<Record<string, unknown>>;
  cause?: unknown;
}

export class LampError extends Error {
  readonly code: ErrorCode;
  readonly safeMessage: string;
  readonly retryable: boolean;
  readonly statusCode: number;
  readonly details: Readonly<Record<string, unknown>>;

  constructor(options: LampErrorOptions) {
    super(options.message, { cause: options.cause });
    this.name = "LampError";
    this.code = options.code;
    this.safeMessage = options.safeMessage ?? "Lamp 暂时无法完成这次请求。";
    this.retryable = options.retryable ?? false;
    this.statusCode = options.statusCode ?? 500;
    this.details = options.details ?? {};
  }

  toJSON(): Record<string, unknown> {
    return {
      name: this.name,
      code: this.code,
      message: this.message,
      safeMessage: this.safeMessage,
      retryable: this.retryable,
      statusCode: this.statusCode,
      details: this.details,
    };
  }
}

export function toLampError(error: unknown): LampError {
  if (error instanceof LampError) return error;
  return new LampError({
    code: "INTERNAL_ERROR",
    message: error instanceof Error ? error.message : "Unknown internal error",
    cause: error,
  });
}

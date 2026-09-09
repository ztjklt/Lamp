import { LampError } from "../../errors/LampError.js";

export class ContextBudget {
  constructor(readonly maximumCharacters = 64_000) {
    if (!Number.isInteger(maximumCharacters) || maximumCharacters < 4_000) {
      throw new LampError({ code: "VALIDATION_ERROR", message: "Context budget must be at least 4000 characters" });
    }
  }

  clip(value: string, maximum: number): string {
    if (value.length <= maximum) return value;
    return `${value.slice(0, Math.max(0, maximum - 24))}\n[TRUNCATED_BY_BUDGET]`;
  }
}

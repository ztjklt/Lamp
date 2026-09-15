import type { Temporal } from "@js-temporal/polyfill";

export interface Clock {
  now(): Temporal.Instant;
}

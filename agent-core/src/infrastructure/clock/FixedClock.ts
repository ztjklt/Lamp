import { Temporal } from "@js-temporal/polyfill";
import type { Clock } from "./Clock.js";

export class FixedClock implements Clock {
  private instant: Temporal.Instant;

  constructor(value: string | Temporal.Instant) {
    this.instant = typeof value === "string" ? Temporal.Instant.from(value) : value;
  }

  now(): Temporal.Instant {
    return this.instant;
  }

  set(value: string | Temporal.Instant): void {
    this.instant = typeof value === "string" ? Temporal.Instant.from(value) : value;
  }

  advance(duration: Temporal.DurationLike): void {
    this.instant = this.instant.add(duration);
  }
}

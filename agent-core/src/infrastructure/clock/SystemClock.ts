import { Temporal } from "@js-temporal/polyfill";
import type { Clock } from "./Clock.js";

export class SystemClock implements Clock {
  now(): Temporal.Instant {
    return Temporal.Now.instant();
  }
}

import { createHash } from "node:crypto";
import { Temporal } from "@js-temporal/polyfill";
import type { ConstraintState, PreferenceState, TimeRange } from "../agent/state/StateModels.js";

export interface NumericRange {
  start: number;
  end: number;
}

export function deterministicUuid(...parts: readonly string[]): string {
  const hex = createHash("sha256").update(parts.join("\u001f")).digest("hex").slice(0, 32).split("");
  hex[12] = "4";
  hex[16] = ["8", "9", "a", "b"][Number.parseInt(hex[16] ?? "0", 16) % 4] ?? "8";
  const value = hex.join("");
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
}

export function toRange(range: TimeRange | { startsAt: string; endsAt: string }): NumericRange {
  if ("startsAt" in range) return { start: Date.parse(range.startsAt), end: Date.parse(range.endsAt) };
  return { start: Date.parse(range.start), end: Date.parse(range.end) };
}

export function overlaps(left: NumericRange, right: NumericRange): boolean {
  return left.start < right.end && right.start < left.end;
}

export function contains(outer: NumericRange, inner: NumericRange): boolean {
  return outer.start <= inner.start && outer.end >= inner.end;
}

export function intersect(left: NumericRange, right: NumericRange): NumericRange | null {
  const range = { start: Math.max(left.start, right.start), end: Math.min(left.end, right.end) };
  return range.end > range.start ? range : null;
}

export function mergeRanges(ranges: readonly NumericRange[]): NumericRange[] {
  const sorted = [...ranges].filter((range) => range.end > range.start)
    .sort((left, right) => left.start - right.start || left.end - right.end);
  const merged: NumericRange[] = [];
  for (const range of sorted) {
    const last = merged.at(-1);
    if (last !== undefined && range.start <= last.end) last.end = Math.max(last.end, range.end);
    else merged.push({ ...range });
  }
  return merged;
}

export function subtractRanges(base: NumericRange, occupied: readonly NumericRange[]): NumericRange[] {
  const result: NumericRange[] = [];
  let cursor = base.start;
  for (const range of mergeRanges(occupied)) {
    if (range.end <= cursor || range.start >= base.end) continue;
    if (range.start > cursor) result.push({ start: cursor, end: Math.min(range.start, base.end) });
    cursor = Math.max(cursor, range.end);
    if (cursor >= base.end) break;
  }
  if (cursor < base.end) result.push({ start: cursor, end: base.end });
  return result;
}

export function blockedConstraintRanges(constraints: readonly ConstraintState[]): NumericRange[] {
  return constraints.filter((constraint) => constraint.type === "USER_BLOCKED_TIME").flatMap((constraint) => {
    const start = constraint.parameters["start"];
    const end = constraint.parameters["end"];
    return typeof start === "string" && typeof end === "string" && Number.isFinite(Date.parse(start)) &&
      Date.parse(end) > Date.parse(start) ? [{ start: Date.parse(start), end: Date.parse(end) }] : [];
  });
}

export function sleepRanges(
  horizon: NumericRange,
  preferences: PreferenceState,
  timeZone: string,
): NumericRange[] {
  if (preferences.preferredSleepTime === null || preferences.preferredWakeTime === null) return [];
  const startDate = Temporal.Instant.fromEpochMilliseconds(horizon.start).toZonedDateTimeISO(timeZone).toPlainDate().subtract({ days: 1 });
  const endDate = Temporal.Instant.fromEpochMilliseconds(horizon.end).toZonedDateTimeISO(timeZone).toPlainDate().add({ days: 1 });
  const sleepTime = Temporal.PlainTime.from(preferences.preferredSleepTime);
  const wakeTime = Temporal.PlainTime.from(preferences.preferredWakeTime);
  const ranges: NumericRange[] = [];
  for (let date = startDate; Temporal.PlainDate.compare(date, endDate) <= 0; date = date.add({ days: 1 })) {
    const sleep = date.toPlainDateTime(sleepTime).toZonedDateTime(timeZone, { disambiguation: "compatible" });
    const wakeDate = Temporal.PlainTime.compare(wakeTime, sleepTime) <= 0 ? date.add({ days: 1 }) : date;
    const wake = wakeDate.toPlainDateTime(wakeTime).toZonedDateTime(timeZone, { disambiguation: "compatible" });
    const clipped = intersect(horizon, {
      start: sleep.toInstant().epochMilliseconds,
      end: wake.toInstant().epochMilliseconds,
    });
    if (clipped !== null) ranges.push(clipped);
  }
  return mergeRanges(ranges);
}

export function localPeriod(epochMilliseconds: number, timeZone: string): "morning" | "afternoon" | "evening" | "night" {
  const hour = Temporal.Instant.fromEpochMilliseconds(epochMilliseconds).toZonedDateTimeISO(timeZone).hour;
  if (hour >= 6 && hour < 12) return "morning";
  if (hour >= 12 && hour < 18) return "afternoon";
  if (hour >= 18 && hour < 23) return "evening";
  return "night";
}

export function minutes(range: NumericRange): number {
  return (range.end - range.start) / 60_000;
}

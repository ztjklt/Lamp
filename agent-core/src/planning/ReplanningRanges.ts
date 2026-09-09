import { Temporal } from "@js-temporal/polyfill";
import type { StateSnapshot } from "../agent/state/StateSnapshot.js";
import type { DomainEvent } from "../events/DomainEvent.js";
import type { ReplanningScope } from "./ReplanningTypes.js";
import type { TimeRange } from "../agent/state/StateModels.js";

export function rangeForScope(scope: ReplanningScope, event: DomainEvent, state: Readonly<StateSnapshot>): TimeRange {
  const horizonStart = Temporal.Instant.from(state.planningHorizon.start);
  const horizonEnd = Temporal.Instant.from(state.planningHorizon.end);
  if (scope === "full") return state.planningHorizon;
  let anchor = eventAnchor(event);
  if (Temporal.Instant.compare(anchor, Temporal.Instant.from(state.now)) < 0) anchor = Temporal.Instant.from(state.now);
  if (Temporal.Instant.compare(anchor, horizonStart) < 0) anchor = horizonStart;
  if (Temporal.Instant.compare(anchor, horizonEnd) >= 0) return state.planningHorizon;

  const zoned = anchor.toZonedDateTimeISO(state.timezone);
  let end: Temporal.Instant;
  if (scope === "local") {
    end = anchor.add({ hours: 4 });
    const eventEnd = eventRangeEnd(event);
    if (eventEnd !== null && Temporal.Instant.compare(eventEnd, end) > 0) end = eventEnd.add({ hours: 2 });
  } else {
    end = zoned.startOfDay().add({ days: scope === "day" ? 1 : 3 }).toInstant();
  }
  if (Temporal.Instant.compare(end, horizonEnd) > 0) end = horizonEnd;
  if (Temporal.Instant.compare(end, anchor) <= 0) return state.planningHorizon;
  return { start: anchor.toString(), end: end.toString() };
}

function eventAnchor(event: DomainEvent): Temporal.Instant {
  if (event.type === "EVENT_ADDED") return Temporal.Instant.from(event.payload.range.start);
  if (event.type === "EVENT_REMOVED") return Temporal.Instant.from(event.payload.previousRange.start);
  return Temporal.Instant.from(event.occurredAt);
}

function eventRangeEnd(event: DomainEvent): Temporal.Instant | null {
  if (event.type === "EVENT_ADDED") return Temporal.Instant.from(event.payload.range.end);
  if (event.type === "EVENT_REMOVED") return Temporal.Instant.from(event.payload.previousRange.end);
  return null;
}

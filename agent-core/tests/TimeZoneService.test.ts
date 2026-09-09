import { describe, expect, it } from "vitest";
import { LampError } from "../src/errors/LampError.js";
import { FixedClock } from "../src/infrastructure/clock/FixedClock.js";
import { TimeZoneService } from "../src/infrastructure/time/TimeZoneService.js";

describe("Clock and TimeZoneService", () => {
  it("provides a controllable clock without reading wall time", () => {
    const clock = new FixedClock("2026-09-08T00:00:00Z");
    clock.advance({ minutes: 30 });
    expect(clock.now().toString()).toBe("2026-09-08T00:30:00Z");
  });

  it("adds local calendar days across daylight-saving transitions", () => {
    const timeZones = new TimeZoneService();
    const clock = new FixedClock("2026-03-08T05:00:00Z");

    const nextDay = timeZones.addCalendarDaysFromStartOfDay(
      clock.now(),
      1,
      "America/New_York",
    );

    expect(nextDay.toString()).toBe("2026-03-09T04:00:00Z");
    expect(nextDay.epochMilliseconds - clock.now().epochMilliseconds).toBe(23 * 60 * 60 * 1_000);
  });

  it("rejects nonexistent local times instead of silently shifting them", () => {
    const timeZones = new TimeZoneService();
    expect(() => timeZones.resolveLocalDateTime(
      "2026-03-08T02:30:00",
      "America/New_York",
      "reject",
    )).toThrowError(LampError);
  });

  it("rejects unknown IANA timezones", () => {
    const timeZones = new TimeZoneService();
    expect(() => timeZones.validate("Moon/Sea_of_Tranquility")).toThrowError(LampError);
  });

  it("canonicalizes IANA aliases and rejects fixed offsets", () => {
    const timeZones = new TimeZoneService();
    expect(timeZones.validate("US/Eastern")).toBe("America/New_York");
    expect(() => timeZones.validate("+08:00")).toThrowError(LampError);
  });
});

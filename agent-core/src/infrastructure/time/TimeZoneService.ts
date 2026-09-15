import { Temporal } from "@js-temporal/polyfill";
import { LampError } from "../../errors/LampError.js";

export class TimeZoneService {
  validate(timeZone: string): string {
    try {
      if (/^[+-]/.test(timeZone)) throw new RangeError("fixed offsets are not IANA timezone identifiers");
      const canonical = new Intl.DateTimeFormat("en", { timeZone }).resolvedOptions().timeZone;
      Temporal.Instant.from("2000-01-01T00:00:00Z").toZonedDateTimeISO(canonical);
      return canonical;
    } catch (error) {
      throw new LampError({
        code: "VALIDATION_ERROR",
        message: `Invalid IANA timezone: ${timeZone}`,
        safeMessage: "用户时区无效。",
        details: { timeZone },
        cause: error,
      });
    }
  }

  startOfDay(instant: Temporal.Instant, timeZone: string): Temporal.Instant {
    const validTimeZone = this.validate(timeZone);
    return instant.toZonedDateTimeISO(validTimeZone).startOfDay().toInstant();
  }

  addCalendarDaysFromStartOfDay(
    instant: Temporal.Instant,
    days: number,
    timeZone: string,
  ): Temporal.Instant {
    if (!Number.isInteger(days) || days < 1) {
      throw new LampError({
        code: "VALIDATION_ERROR",
        message: "Calendar day count must be a positive integer",
        details: { days },
      });
    }
    const validTimeZone = this.validate(timeZone);
    return instant
      .toZonedDateTimeISO(validTimeZone)
      .startOfDay()
      .add({ days })
      .toInstant();
  }

  resolveLocalDateTime(
    localDateTime: string,
    timeZone: string,
    disambiguation: "compatible" | "earlier" | "later" | "reject" = "reject",
  ): Temporal.Instant {
    const validTimeZone = this.validate(timeZone);
    try {
      return Temporal.PlainDateTime.from(localDateTime)
        .toZonedDateTime(validTimeZone, { disambiguation })
        .toInstant();
    } catch (error) {
      throw new LampError({
        code: "VALIDATION_ERROR",
        message: `Invalid or ambiguous local date-time: ${localDateTime}`,
        safeMessage: "日期或时间无效，或受到夏令时切换影响。",
        details: { localDateTime, timeZone: validTimeZone, disambiguation },
        cause: error,
      });
    }
  }
}

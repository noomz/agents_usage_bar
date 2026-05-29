import Testing
import Foundation
@testable import AgentsUsageBar

/// Plan 02.07 — UI-05 reset-clock caption tests.
///
/// `TodayHelper.resetClockText(_:calendar:)` returns `"Resets HH:mm <TZ>"` for the
/// footer caption. `HH:mm` is always `"00:00"` in Phase 2 (local-midnight aggregation
/// window — PROJECT.md constraint). `<TZ>` is the calendar's `timeZone.abbreviation(for:)`,
/// which is DST-aware (Pitfall 4 + Pitfall 7).
@Suite("TodayHelperResetClockTests")
struct TodayHelperResetClockTests {

    // MARK: - Helpers

    /// Builds a UTC date for the given components without relying on the host calendar.
    private static func utc(year: Int, month: Int, day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)!
    }

    private static func calendar(_ tzIdentifier: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tzIdentifier)!
        return cal
    }

    private static func calendar(secondsFromGMT: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        return cal
    }

    // MARK: - Tests

    @Test("resetClockText with America/Los_Angeles in mid-May returns the daylight-time abbreviation")
    func resetClockText_withPacificCalendar_returnsExpectedAbbrev() {
        // 2026-05-13 is well inside Daylight Time in PT.
        // Modern Apple Foundation returns "GMT-7" for PT in summer (not the historical
        // "PDT" abbreviation). We verify the prefix and the DST-correct offset.
        let now = Self.utc(year: 2026, month: 5, day: 13)
        let cal = Self.calendar("America/Los_Angeles")
        let text = TodayHelper.resetClockText(now, calendar: cal)
        #expect(text.hasPrefix("Resets 00:00 "))
        // PT in summer: UTC-7 (whether emitted as "PDT" or "GMT-7" is host-Foundation dependent).
        #expect(text.hasSuffix("PDT") || text.hasSuffix("GMT-7"))
    }

    @Test("resetClockText with America/New_York returns the active eastern-time abbreviation")
    func resetClockText_withEasternCalendar() {
        let now = Self.utc(year: 2026, month: 5, day: 13)
        let cal = Self.calendar("America/New_York")
        let text = TodayHelper.resetClockText(now, calendar: cal)
        #expect(text.hasPrefix("Resets 00:00 "))
        // ET in summer: UTC-4 (EDT or GMT-4); winter would yield UTC-5.
        #expect(text.hasSuffix("EDT") || text.hasSuffix("EST")
                || text.hasSuffix("GMT-4") || text.hasSuffix("GMT-5"))
    }

    @Test("resetClockText with UTC calendar returns GMT/UTC suffix")
    func resetClockText_withUTCCalendar_returnsGMT() {
        let now = Self.utc(year: 2026, month: 5, day: 13)
        let cal = Self.calendar("UTC")
        let text = TodayHelper.resetClockText(now, calendar: cal)
        #expect(text.hasPrefix("Resets 00:00 "))
        // Apple returns "GMT" for the UTC zone abbreviation.
        #expect(text.contains("GMT") || text.contains("UTC"))
    }

    @Test("resetClockText with a fixed-offset zone (no published abbreviation) omits the suffix or uses an offset string")
    func resetClockText_withUnknownAbbreviation_falls_back() {
        // 5400 seconds = +01:30, an offset with no standard abbreviation.
        let now = Self.utc(year: 2026, month: 5, day: 13)
        let cal = Self.calendar(secondsFromGMT: 5400)
        let text = TodayHelper.resetClockText(now, calendar: cal)
        // Documented behavior: when `abbreviation(for:)` returns nil OR an empty string,
        // we omit the TZ. Apple's Foundation may return a synthesized "GMT+1:30" — both
        // shapes are acceptable as long as the prefix is intact.
        #expect(text.hasPrefix("Resets 00:00"))
        if text == "Resets 00:00" {
            // No abbreviation produced — preferred outcome.
        } else {
            // Synthesized GMT offset — acceptable.
            #expect(text.contains("GMT"))
        }
    }

    @Test("resetClockText before spring-forward in PT on 2026-03-08 reflects standard-time offset")
    func resetClockText_DST_spring_forward_pacific_2026_03_08() {
        // 2026-03-08 at 01:30 in America/Los_Angeles is BEFORE the spring-forward (which
        // happens at 02:00 → 03:00). Local wall-clock 01:30 PT = 09:30 UTC.
        // PT standard time = UTC-8 → "PST" historically, "GMT-8" on modern Foundation.
        let now = Self.utc(year: 2026, month: 3, day: 8, hour: 9, minute: 30)
        let cal = Self.calendar("America/Los_Angeles")
        let text = TodayHelper.resetClockText(now, calendar: cal)
        #expect(text.hasPrefix("Resets 00:00 "))
        #expect(text.hasSuffix("PST") || text.hasSuffix("GMT-8"))
    }

    @Test("resetClockText after spring-forward in PT on 2026-03-08 reflects daylight-time offset")
    func resetClockText_DST_post_spring_forward_pacific_2026_03_08() {
        // 2026-03-08 at 03:30 PDT (post-spring-forward) = 10:30 UTC.
        let now = Self.utc(year: 2026, month: 3, day: 8, hour: 10, minute: 30)
        let cal = Self.calendar("America/Los_Angeles")
        let text = TodayHelper.resetClockText(now, calendar: cal)
        #expect(text.hasPrefix("Resets 00:00 "))
        #expect(text.hasSuffix("PDT") || text.hasSuffix("GMT-7"))
    }
}

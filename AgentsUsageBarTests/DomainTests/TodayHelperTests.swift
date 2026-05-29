import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("TodayHelperTests")
struct TodayHelperTests {

    /// Build a Calendar pinned to America/Los_Angeles for deterministic DST tests.
    private static func ptCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return cal
    }

    /// Parse a UTC date string (yyyy-MM-dd'T'HH:mm:ssZ) into a Date.
    private static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    // MARK: todayInterval

    @Test("todayInterval spans local day — PT no DST (2026-03-15)")
    func todayIntervalSpansLocalDay_PT_noDST() {
        let cal = Self.ptCalendar()
        // 2026-03-15 14:00 PT = 22:00 UTC (standard time, UTC-8)
        let now = Self.date("2026-03-15T22:00:00Z")
        let interval = TodayHelper.todayInterval(now, calendar: cal)
        #expect(abs(interval.duration - 86400) < 1)
    }

    @Test("todayInterval handles DST spring-forward (2026-03-08, US DST starts)")
    func todayIntervalHandles_DST_springForward() {
        let cal = Self.ptCalendar()
        // 2026-03-08 14:00 PT (daylight savings begins at 2am — PT goes UTC-8 → UTC-7)
        // 2026-03-08 14:00 PDT = 21:00 UTC
        let now = Self.date("2026-03-08T21:00:00Z")
        let interval = TodayHelper.todayInterval(now, calendar: cal)
        // DST spring-forward day is 23 hours = 82800s
        #expect(abs(interval.duration - 82800) < 5)
    }

    @Test("todayInterval handles DST fall-back (2026-11-01, US DST ends)")
    func todayIntervalHandles_DST_fallBack() {
        let cal = Self.ptCalendar()
        // 2026-11-01 is when clocks fall back in the US (DST ends at 2am PT)
        // 2026-11-01 10:00 PST = 18:00 UTC
        let now = Self.date("2026-11-01T18:00:00Z")
        let interval = TodayHelper.todayInterval(now, calendar: cal)
        // DST fall-back day is 25 hours = 90000s
        #expect(abs(interval.duration - 90000) < 10)
    }

    // MARK: crossedDayBoundary

    @Test("crossedDayBoundary at 23:59 → 00:01 PT returns true")
    func crossedDayBoundaryAt_2359_to_0001_PT() {
        let cal = Self.ptCalendar()
        // 2026-05-11 23:59 PT = 2026-05-12 06:59 UTC (PDT = UTC-7)
        let a = Self.date("2026-05-12T06:59:00Z")
        // 2026-05-12 00:01 PT = 2026-05-12 07:01 UTC
        let b = Self.date("2026-05-12T07:01:00Z")
        #expect(TodayHelper.crossedDayBoundary(from: a, to: b, calendar: cal) == true)
    }

    @Test("crossedDayBoundary same day PT returns false")
    func crossedDayBoundary_same_day_PT() {
        let cal = Self.ptCalendar()
        // Both on 2026-05-11 in PT
        let a = Self.date("2026-05-11T08:01:00Z")  // 00:01 PDT
        let b = Self.date("2026-05-12T06:59:00Z")  // 23:59 PDT
        #expect(TodayHelper.crossedDayBoundary(from: a, to: b, calendar: cal) == false)
    }

    // MARK: formatYYYYMMDD

    @Test("formatYYYYMMDD uses local calendar day (PT)")
    func formatYYYYMMDD_PT() {
        let cal = Self.ptCalendar()
        // 2026-05-11 14:00 PT (PDT = UTC-7) → 2026-05-11 21:00 UTC
        let date = Self.date("2026-05-11T21:00:00Z")
        let result = TodayHelper.formatYYYYMMDD(date, calendar: cal)
        #expect(result == "2026-05-11")
    }
}

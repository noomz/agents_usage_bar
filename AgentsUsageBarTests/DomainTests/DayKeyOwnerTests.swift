import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("DayKeyOwnerTests")
struct DayKeyOwnerTests {

    private static let bangkok = TimeZone(identifier: "Asia/Bangkok")!

    /// A Thai-locale host's `Calendar.current`: Buddhist era, year 2569 for 2026.
    private static func buddhistCalendar() -> Calendar {
        var cal = Calendar(identifier: .buddhist)
        cal.timeZone = bangkok
        return cal
    }

    /// Parse a UTC date string (yyyy-MM-dd'T'HH:mm:ssZ) into a Date.
    private static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private static func owner(at iso: String, timeZone: TimeZone = bangkok) -> DayKeyOwner {
        DayKeyOwner(
            clock: VirtualClock(fixed: date(iso)),
            timeZone: timeZone,
            legacyCalendar: buddhistCalendar()
        )
    }

    // MARK: V2 — Gregorian key whatever the locale calendar

    @Test("today is a Gregorian key on a Buddhist-calendar host")
    func todayIsGregorianOnBuddhistHost() {
        // 2026-10-22 10:00 ICT = 03:00 UTC
        let owner = Self.owner(at: "2026-10-22T03:00:00Z")
        #expect(owner.today() == "2026-10-22")
        #expect(owner.legacyKey(for: Self.date("2026-10-22T03:00:00Z")) == "2569-10-22")
    }

    @Test("today follows the injected clock")
    func todayFollowsClock() {
        var now = Self.date("2026-10-22T03:00:00Z")
        let owner = DayKeyOwner(
            clock: VirtualClock { now },
            timeZone: Self.bangkok,
            legacyCalendar: Self.buddhistCalendar()
        )
        #expect(owner.today() == "2026-10-22")
        now = Self.date("2026-10-23T03:00:00Z")
        #expect(owner.today() == "2026-10-23")
    }

    @Test("key uses the current zone's local midnight, not UTC")
    func keyUsesLocalZone() {
        // 2026-10-22 23:30 UTC is 2026-10-23 06:30 in Bangkok and 2026-10-22 16:30 in LA.
        let instant = "2026-10-22T23:30:00Z"
        #expect(Self.owner(at: instant).today() == "2026-10-23")
        let la = TimeZone(identifier: "America/Los_Angeles")!
        #expect(Self.owner(at: instant, timeZone: la).today() == "2026-10-22")
    }

    // MARK: V3 — legacy same-day keys count as today

    @Test("a legacy key for the same date counts as the same day")
    func legacyKeySameDayMatches() {
        let now = Self.date("2026-10-22T03:00:00Z")
        let owner = Self.owner(at: "2026-10-22T03:00:00Z")
        #expect(owner.isSameDay("2569-10-22", as: now))
        #expect(owner.isSameDay("2026-10-22", as: now))
    }

    @Test("a legacy or day key for another date does not match")
    func otherDayDoesNotMatch() {
        let now = Self.date("2026-10-22T03:00:00Z")
        let owner = Self.owner(at: "2026-10-22T03:00:00Z")
        #expect(!owner.isSameDay("2569-10-21", as: now))
        #expect(!owner.isSameDay("2026-10-21", as: now))
        #expect(!owner.isSameDay("2026-10-22-x", as: now))
    }

    @Test("a legacy key converts to the day key for the same date")
    func legacyKeyConverts() {
        let owner = Self.owner(at: "2026-10-22T03:00:00Z")
        #expect(owner.key(fromLegacy: "2569-10-22") == "2026-10-22")
        #expect(owner.key(fromLegacy: "2569-01-01") == "2026-01-01")
    }

    @Test("a value that is not a yyyy-MM-dd key does not convert")
    func nonKeyDoesNotConvert() {
        let owner = Self.owner(at: "2026-10-22T03:00:00Z")
        #expect(owner.key(fromLegacy: "") == nil)
        #expect(owner.key(fromLegacy: "2569-10") == nil)
        #expect(owner.key(fromLegacy: "2569-10-x") == nil)
        #expect(owner.key(fromLegacy: "migrated") == nil)
    }

    // MARK: V4, V5 — the key never decreases

    @Test("the key holds at the newest key when the wall clock is behind it, for every copy (V1, V4)")
    func keyHoldsAtNewest() {
        let owner = Self.owner(at: "2026-10-22T03:00:00Z")
        let consumerCopy = owner
        owner.advanceNewest(to: "2026-10-22")

        // 2026-10-21 10:00 ICT
        let dayBefore = Self.date("2026-10-21T03:00:00Z")
        #expect(owner.wallKey(for: dayBefore) == "2026-10-21")
        #expect(consumerCopy.key(for: dayBefore) == "2026-10-22")
        #expect(consumerCopy.isSameDay("2026-10-22", as: dayBefore))
        // A later wall date still moves the key forward.
        #expect(consumerCopy.key(for: Self.date("2026-10-23T03:00:00Z")) == "2026-10-23")
    }

    @Test("the newest key never goes down")
    func newestOnlyRises() {
        let owner = Self.owner(at: "2026-10-01T03:00:00Z")
        owner.advanceNewest(to: "2026-10-22")
        owner.advanceNewest(to: "2026-10-05")
        #expect(owner.today() == "2026-10-22")
    }

    @Test("key arithmetic and legacy rekeying ignore the newest key")
    func pureConversionsIgnoreNewest() {
        let owner = Self.owner(at: "2026-10-22T03:00:00Z")
        owner.advanceNewest(to: "2026-12-31")
        #expect(owner.key("2026-10-22", addingDays: -90) == "2026-07-24")
        #expect(owner.key(fromLegacy: "2569-10-20") == "2026-10-20")
    }

    @Test("a clock error is a wall date more than 1 day behind the newest key (V5)")
    func clockBehind() {
        let owner = Self.owner(at: "2026-10-22T03:00:00Z")
        #expect(!owner.isClockBehind(at: Self.date("2026-10-12T03:00:00Z")))

        owner.advanceNewest(to: "2026-10-22")
        #expect(!owner.isClockBehind(at: Self.date("2026-10-22T03:00:00Z")))
        #expect(!owner.isClockBehind(at: Self.date("2026-10-21T03:00:00Z")))
        #expect(owner.isClockBehind(at: Self.date("2026-10-20T03:00:00Z")))
        #expect(owner.isClockBehind(at: Self.date("2026-10-12T03:00:00Z")))
    }
}

import Foundation

/// The one owner of the day key: the local date every "today" consumer files its state under
/// (SPEC V1).
///
/// A day key is `yyyy-MM-dd` from a Gregorian calendar in the current time zone, whatever
/// calendar the user's locale uses (V2). `Calendar.current` on a Thai-locale host is Buddhist,
/// so `TodayHelper.formatYYYYMMDD` with its default calendar gives `2569-10-22` where the day
/// key is `2026-10-22`. Builds before S0 stored those locale-calendar keys in `today.json` and
/// notification state; `isSameDay(_:as:)` still counts them as today on the same date (V3).
public struct DayKeyOwner: Sendable {
    private let clock: any Clock
    private let timeZone: TimeZone
    private let legacyCalendar: Calendar

    /// - Parameters:
    ///   - timeZone: Defaults to `.autoupdatingCurrent` so a time-zone change is picked up
    ///     without a relaunch.
    ///   - legacyCalendar: The calendar pre-S0 builds keyed with. Defaults to
    ///     `.autoupdatingCurrent`; tests inject a Buddhist calendar.
    public init(
        clock: any Clock = SystemClock(),
        timeZone: TimeZone = .autoupdatingCurrent,
        legacyCalendar: Calendar = .autoupdatingCurrent
    ) {
        self.clock = clock
        self.timeZone = timeZone
        self.legacyCalendar = legacyCalendar
    }

    /// The day key for the clock's current time.
    public func today() -> String {
        key(for: clock.now())
    }

    /// The day key for `date`.
    public func key(for date: Date) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        return TodayHelper.formatYYYYMMDD(date, calendar: gregorian)
    }

    /// The current time zone id, stored as a day file's last zone seen (V6).
    public var timeZoneIdentifier: String {
        timeZone.identifier
    }

    /// The day key `days` calendar days after `key` (before it when negative), or nil when
    /// `key` is not `yyyy-MM-dd`.
    public func key(_ key: String, addingDays days: Int) -> String? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        // Noon keeps a DST shift from moving the date.
        guard let date = gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
              let shifted = gregorian.date(byAdding: .day, value: days, to: date)
        else { return nil }
        return self.key(for: shifted)
    }

    /// The key a pre-S0 build stored for `date`: `yyyy-MM-dd` in the locale's calendar.
    public func legacyKey(for date: Date) -> String {
        TodayHelper.formatYYYYMMDD(date, calendar: legacyCalendar)
    }

    /// True when `stored` names the same day as `date`, as a day key or a legacy key.
    public func isSameDay(_ stored: String, as date: Date) -> Bool {
        stored == key(for: date) || stored == legacyKey(for: date)
    }

    /// The day key for a `yyyy-MM-dd` key a pre-S0 build stored in the locale's calendar, or
    /// nil when `legacy` is not that shape. Only correct for keys known to be legacy: on a
    /// Buddhist host a day key read this way lands 543 years early.
    public func key(fromLegacy legacy: String) -> String? {
        let parts = legacy.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = legacyCalendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return nil }
        return key(for: date)
    }
}

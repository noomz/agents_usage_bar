import Foundation

/// Helpers for computing "today" in the user's local calendar timezone.
///
/// UI-04, D-05: All boundaries are computed using `Calendar.current`, which reads the
/// user's timezone from system settings. NEVER use `Calendar(identifier:)` directly —
/// that constructs a calendar with UTC timezone, causing "today" to reset at 4pm in PT
/// (Pitfall 4: "Today computed in UTC, not user's local midnight").
///
/// Similarly, NEVER use `DateFormatter()` or `ISO8601DateFormatter` for YYYY-MM-DD
/// formatting — their default timezone is UTC. Use `DateComponents` extraction instead
/// (see `formatYYYYMMDD`).
public enum TodayHelper {

    /// Returns the half-open [start, end) `DateInterval` that covers "today" in the
    /// user's current calendar and timezone.
    ///
    /// Honors DST automatically — `Calendar` handles 23-hour, 24-hour, and 25-hour days.
    /// Calling code should pass `calendar: .current` (the default) in production.
    /// Tests inject a pinned calendar (e.g. America/Los_Angeles) for deterministic DST assertions.
    public static func todayInterval(
        _ now: Date = .now,
        calendar: Calendar = .current
    ) -> DateInterval {
        // Force-unwrap is safe: every date belongs to exactly one day in every calendar.
        return calendar.dateInterval(of: .day, for: now)!
    }

    /// Returns the start-of-day `Date` for `now` in the given calendar (default: `.current`).
    public static func startOfDay(
        _ now: Date = .now,
        calendar: Calendar = .current
    ) -> Date {
        return calendar.startOfDay(for: now)
    }

    /// Returns `true` iff `a` and `b` fall on different local calendar days.
    ///
    /// Used by `FileCacheStore.maintainBaseline` (D-05) to detect midnight rollover
    /// without a separate timer.
    public static func crossedDayBoundary(
        from a: Date,
        to b: Date,
        calendar: Calendar = .current
    ) -> Bool {
        return calendar.startOfDay(for: a) != calendar.startOfDay(for: b)
    }

    /// Returns a `"YYYY-MM-DD"` string for `date` in the given calendar (default: `.current`).
    ///
    /// Used to produce stable notification identifiers (e.g. `"openrouter:2026-05-11:warn80"`)
    /// and baseline-date keys in the cache.
    ///
    /// IMPORTANT: Uses `DateComponents` extraction — NOT `DateFormatter` or
    /// `ISO8601DateFormatter`, both of which default to UTC and would produce the wrong
    /// date for users in UTC- timezones after 4–5 pm local time (Pitfall 4).
    public static func formatYYYYMMDD(
        _ date: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
    }
}

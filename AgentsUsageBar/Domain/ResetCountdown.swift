import Foundation

/// Compact remaining-time phrase for quota-window reset countdowns.
///
/// Two most-significant units, matching the glance-bar / `aub usage` caption:
///   - `interval <= 0` → `Resets now`
///   - `< 1m`          → `Resets <1m`
///   - `< 1h`          → `Resets Xm`
///   - `< 24h`         → `Resets Xh Ym` (omit `0m`)
///   - `≥ 24h`         → `Resets Xd Yh` (omit `0h`)
public enum ResetCountdown {
    public static func phrase(until date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "Resets now" }
        return "Resets \(compact(interval))"
    }

    public static func compact(_ interval: TimeInterval) -> String {
        let t = max(0, interval)
        if t < 60 { return "<1m" }
        let totalMinutes = Int(t / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days >= 1 {
            if hours == 0 { return "\(days)d" }
            return "\(days)d \(hours)h"
        }
        let totalHours = totalMinutes / 60
        if totalHours >= 1 {
            if minutes == 0 { return "\(totalHours)h" }
            return "\(totalHours)h \(minutes)m"
        }
        return "\(totalMinutes)m"
    }
}

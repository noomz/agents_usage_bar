import Foundation
import Darwin

/// Formatting primitives shared by every CLI theme: ANSI band colour, bar
/// glyphs, token / USD / percent text and reset phrases. Row layout stays
/// inside each theme.
public enum CLIFormat {

    // MARK: - Colour

    public static func ansiCode(for band: QuotaBand) -> String {
        switch band {
        case .none:     return "\u{001B}[90m"
        case .critical: return "\u{001B}[31m"
        case .warning:  return "\u{001B}[33m"
        case .healthy:  return "\u{001B}[32m"
        }
    }

    public static let ansiReset = "\u{001B}[0m"

    /// Wraps `text` in the band's ANSI colour when `color` is on.
    public static func paint(_ text: String, band: QuotaBand, color: Bool) -> String {
        color ? ansiCode(for: band) + text + ansiReset : text
    }

    public static func shouldColor(noColor: Bool, isTTY: Bool? = nil) -> Bool {
        if noColor { return false }
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        if ProcessInfo.processInfo.environment["TERM"] == "dumb" { return false }
        return isTTY ?? (isatty(STDOUT_FILENO) != 0)
    }

    // MARK: - Bars

    /// Whole-cell consumed-fraction fill. `nil` quota → a full bar ("no limit").
    public static func blockBar(consumed: Double?, width: Int) -> String {
        guard let consumed else {
            return String(repeating: "█", count: width)
        }
        let clamped = min(max(consumed, 0), 1)
        var filled = Int((clamped * Double(width)).rounded(.toNearestOrAwayFromZero))
        filled = min(width, max(0, filled))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }

    // MARK: - Text

    /// Grouped integer, e.g. `1,204,331`.
    public static func tokens(_ n: Int) -> String {
        n.formatted(.number)
    }

    /// USD amount, e.g. `$273.86`.
    public static func usd(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: "USD"))
    }

    /// Consumed fraction as a whole percent, e.g. `0.469` → `47%`.
    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// `Resets 2h 50m` style countdown from `now` (callers pass `report.asOf`).
    public static func resetsPhrase(until date: Date, now: Date) -> String {
        ResetCountdown.phrase(until: date, now: now)
    }

    /// Right-pads `s` with spaces to `n` characters; longer strings pass through.
    public static func pad(_ s: String, to n: Int) -> String {
        if s.count >= n { return s }
        return s + String(repeating: " ", count: n - s.count)
    }
}

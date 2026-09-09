import Foundation
import Darwin

/// ASCII popover clone for `aub usage` / `aub quota`.
public enum UsageTextRenderer {

    public static let barWidth = 20

    /// Consumed-fraction fill, width 20. `nil` quota → a full gray bar ("no limit").
    public static func bar(consumed: Double?, width: Int = barWidth) -> String {
        guard let consumed else {
            return String(repeating: "█", count: width)
        }
        let clamped = min(max(consumed, 0), 1)
        var filled = Int((clamped * Double(width)).rounded(.toNearestOrAwayFromZero))
        filled = min(width, max(0, filled))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }

    public static func ansiCode(for band: QuotaBand) -> String {
        switch band {
        case .none:     return "\u{001B}[90m"
        case .critical: return "\u{001B}[31m"
        case .warning:  return "\u{001B}[33m"
        case .healthy:  return "\u{001B}[32m"
        }
    }

    public static let ansiReset = "\u{001B}[0m"

    public static func shouldColor(noColor: Bool, isTTY: Bool? = nil) -> Bool {
        if noColor { return false }
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        if ProcessInfo.processInfo.environment["TERM"] == "dumb" { return false }
        return isTTY ?? (isatty(STDOUT_FILENO) != 0)
    }

    public static func renderUsage(_ report: UsageReport, color: Bool) -> String {
        var lines: [String] = []
        let nameWidth = max(16, report.providers.map(\.displayName.count).max() ?? 16)
        lines.append(totalsLine(report.totals, nameWidth: nameWidth))
        if report.hasAnyQuotaOnlyProvider {
            lines.append("Total excludes quota-only providers")
        }
        lines.append(String(repeating: "─", count: 57))
        for p in report.providers {
            lines.append(contentsOf: usageBlock(p, nameWidth: nameWidth, color: color, now: report.asOf))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func renderQuota(_ report: UsageReport, color: Bool) -> String {
        var lines: [String] = []
        let nameWidth = max(16, report.providers.map(\.displayName.count).max() ?? 16)
        for p in report.providers {
            lines.append(contentsOf: quotaBlock(p, nameWidth: nameWidth, color: color, now: report.asOf))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Blocks

    private static func totalsLine(_ totals: DailyTotals, nameWidth: Int) -> String {
        let left = pad("Today total", to: nameWidth)
        let tokens = "\(totals.tokens.formatted(.number)) tokens"
        let usd = totals.costUSD.formatted(.currency(code: "USD"))
        return "\(left)  \(pad(tokens, to: 22))  \(usd)"
    }

    private static func usageBlock(
        _ p: ProviderReport,
        nameWidth: Int,
        color: Bool,
        now: Date
    ) -> [String] {
        var lines: [String] = []
        let name = pad(p.displayName, to: nameWidth)
        if p.isLocal {
            let caption = localCaption(p)
            lines.append("\(name)  \(caption)")
            return lines
        }
        let (barLine, band) = quotaBarLine(p.snapshot?.displayedQuota, color: color)
        lines.append("\(name)  \(barLine)")
        lines.append("\(pad("", to: nameWidth))  \(secondaryLine(p))")
        if let windows = p.snapshot?.quotaWindows, !windows.isEmpty {
            lines.append("\(pad("", to: nameWidth))  \(windowsLine(windows, now: now))")
        }
        if let accounts = p.snapshot?.accounts, accounts.count >= 2 {
            for account in accounts {
                lines.append(contentsOf: accountLines(account, nameWidth: nameWidth, color: color, now: now, band: band))
            }
        }
        if isDegraded(p) {
            lines.append("\(pad("", to: nameWidth))  usage temporarily unavailable")
        }
        return lines
    }

    private static func quotaBlock(
        _ p: ProviderReport,
        nameWidth: Int,
        color: Bool,
        now: Date
    ) -> [String] {
        var lines: [String] = []
        let name = pad(p.displayName, to: nameWidth)
        let (barLine, _) = quotaBarLine(p.snapshot?.displayedQuota, color: color)
        lines.append("\(name)  \(barLine)")
        if let windows = p.snapshot?.quotaWindows, !windows.isEmpty {
            for w in windows {
                let pct = w.utilization.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
                let reset = w.resetsAt.map { resetsPhrase(until: $0, now: now) } ?? "—"
                lines.append("\(pad("", to: nameWidth))  \(w.name)  \(pct)  \(reset)")
            }
        }
        if isDegraded(p) {
            lines.append("\(pad("", to: nameWidth))  usage temporarily unavailable")
        }
        return lines
    }

    private static func quotaBarLine(_ quota: Quota?, color: Bool) -> (String, QuotaBand) {
        let consumed = quota?.fraction
        let remaining: Double? = quota.map { 1.0 - $0.fraction }
        let band = QuotaBand.fromRemainingFraction(remaining)
        var bar = Self.bar(consumed: consumed)
        if color {
            bar = ansiCode(for: band) + bar + ansiReset
        }
        let label: String
        if let quota {
            label = "\(Int((quota.fraction * 100).rounded()))%"
        } else {
            label = "no limit"
        }
        return ("\(bar)  \(label)", band)
    }

    private static func secondaryLine(_ p: ProviderReport) -> String {
        if let caption = p.snapshot?.quotaUsageCaption {
            return caption
        }
        let tokens: String = {
            guard let n = p.snapshot?.tokensToday else { return "—" }
            return "\(n.formatted(.number)) tokens"
        }()
        let usd: String = {
            guard let c = p.snapshot?.costTodayUSD else { return "—" }
            return c.formatted(.currency(code: "USD"))
        }()
        var parts = [tokens, usd]
        if let bal = p.snapshot?.balanceUSD {
            parts.append("bal " + bal.formatted(.currency(code: "USD")))
        }
        return parts.joined(separator: " · ")
    }

    private static func windowsLine(_ windows: [QuotaWindow], now: Date) -> String {
        windows.map { w in
            let pct = w.utilization.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
            if let reset = w.resetsAt {
                return "\(w.name) \(pct)  \(resetsPhrase(until: reset, now: now))"
            }
            return "\(w.name) \(pct)"
        }.joined(separator: " · ")
    }

    private static func accountLines(
        _ account: UsageSnapshot.AccountUsage,
        nameWidth: Int,
        color: Bool,
        now: Date,
        band: QuotaBand
    ) -> [String] {
        _ = band
        let indent = pad("", to: nameWidth)
        var head = "  \(account.name)"
        if let cost = account.costTodayUSD {
            head += " · " + cost.formatted(.currency(code: "USD"))
        }
        let (barLine, _) = quotaBarLine(account.displayedQuota, color: color)
        var lines = ["\(indent)  \(head)", "\(indent)  \(barLine)"]
        if let soonest = account.displayedResetsAt {
            lines.append("\(indent)  \(resetsPhrase(until: soonest, now: now))")
        }
        return lines
    }

    private static func isDegraded(_ p: ProviderReport) -> Bool {
        p.snapshot?.raw["note"] == ThresholdEngine.degradedTag
    }

    private static func localCaption(_ p: ProviderReport) -> String {
        let state = ProviderState(
            id: p.id,
            displayName: p.displayName,
            placeholderMessage: p.placeholderMessage,
            snapshot: p.snapshot,
            status: p.status,
            lastSuccess: nil
        )
        return state.localSecondaryCaption
    }

    public static func resetsPhrase(until date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "Resets now" }
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 24 {
            let days = hours / 24
            let remH = hours % 24
            return "Resets \(days)d \(remH)h"
        }
        if hours >= 1 { return "Resets \(hours)h \(minutes)m" }
        if totalMinutes >= 1 { return "Resets \(totalMinutes)m" }
        return "Resets <1m"
    }

    private static func pad(_ s: String, to n: Int) -> String {
        if s.count >= n { return s }
        return s + String(repeating: " ", count: n - s.count)
    }
}

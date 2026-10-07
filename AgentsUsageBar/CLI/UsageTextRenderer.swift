import Foundation

/// ASCII popover clone for `aub usage` / `aub quota`.
public enum UsageTextRenderer {

    public static let barWidth = 20

    /// Consumed-fraction fill, width 20. `nil` quota → a full gray bar ("no limit").
    public static func bar(consumed: Double?, width: Int = barWidth) -> String {
        CLIFormat.blockBar(consumed: consumed, width: width)
    }

    public static func ansiCode(for band: QuotaBand) -> String {
        CLIFormat.ansiCode(for: band)
    }

    public static let ansiReset = CLIFormat.ansiReset

    public static func shouldColor(noColor: Bool, isTTY: Bool? = nil) -> Bool {
        CLIFormat.shouldColor(noColor: noColor, isTTY: isTTY)
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
        let tokens = "\(CLIFormat.tokens(totals.tokens)) tokens"
        let usd = CLIFormat.usd(totals.costUSD)
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
        let glance = p.id == .claude ? p.snapshot?.quotaGlance : nil
        let activeQuota = glance?.active?.utilization.map { Quota(used: $0, limit: 1, remaining: max(0, 1 - $0)) }
        let barLine: String
        if let glance, glance.hasAnyWindow {
            barLine = claudeDualBarLine(glance)
        } else {
            barLine = quotaBarLine(activeQuota ?? p.snapshot?.displayedQuota, color: color).0
        }
        lines.append("\(name)  \(barLine)")
        lines.append("\(pad("", to: nameWidth))  \(secondaryLine(p))")
        let accounts = p.snapshot?.accounts
        if let glance, glance.hasAnyWindow {
            lines.append(contentsOf: claudeUsageLines(glance, nameWidth: nameWidth, now: now))
        }
        if p.id == .codex, let accounts, accounts.count >= 2 {
            for account in accounts {
                lines.append(contentsOf: codexUsageAccountLines(account, nameWidth: nameWidth, color: color, now: now))
            }
        } else if let accounts, accounts.count >= 2 {
            for account in accounts {
                lines.append(contentsOf: accountLines(account, nameWidth: nameWidth, color: color, now: now))
            }
        } else if !(glance?.hasAnyWindow ?? false), let windows = p.snapshot?.quotaWindows, !windows.isEmpty {
            lines.append(contentsOf: windowLines(windows, nameWidth: nameWidth, now: now))
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
        if p.id == .codex, let accounts = p.snapshot?.accounts, accounts.count >= 2 {
            for account in accounts {
                lines.append(contentsOf: codexQuotaAccountLines(account, nameWidth: nameWidth, now: now))
            }
        } else if let windows = p.snapshot?.quotaWindows, !windows.isEmpty {
            lines.append(contentsOf: windowLines(windows, nameWidth: nameWidth, now: now))
        }
        if isDegraded(p) {
            lines.append("\(pad("", to: nameWidth))  usage temporarily unavailable")
        }
        return lines
    }

    /// 20-cell Claude dual-limit glyph bar from approved prototype.
    /// `▀` = 5h only, `▄` = 7d only, `█` = both, `░` = neither.
    private static func claudeDualBarLine(_ glance: QuotaGlance) -> String {
        let five = glance.fiveHours?.utilization
        let seven = glance.sevenDays?.utilization
        let glyphs = (1...barWidth).map { cell -> Character in
            let edge = Double(cell) / Double(barWidth)
            let fiveFilled = five.map { $0 >= edge } ?? false
            let sevenFilled = seven.map { $0 >= edge } ?? false
            return switch (fiveFilled, sevenFilled) {
            case (true, true): "█"
            case (true, false): "▀"
            case (false, true): "▄"
            case (false, false): "░"
            }
        }
        return "\(String(glyphs))  5h \(glance.percent(for: .fiveHours)) · 7d \(glance.percent(for: .sevenDays))"
    }

    private static func quotaBarLine(_ quota: Quota?, color: Bool) -> (String, QuotaBand) {
        let consumed = quota?.fraction
        let remaining: Double? = quota.map { 1.0 - $0.fraction }
        let band = QuotaBand.fromRemainingFraction(remaining)
        let bar = CLIFormat.paint(Self.bar(consumed: consumed), band: band, color: color)
        let label: String
        if let quota {
            label = CLIFormat.percent(quota.fraction)
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
            return "\(CLIFormat.tokens(n)) tokens"
        }()
        let usd: String = {
            guard let c = p.snapshot?.costTodayUSD else { return "—" }
            return CLIFormat.usd(c)
        }()
        var parts = [tokens, usd]
        if let bal = p.snapshot?.balanceUSD {
            parts.append("bal " + CLIFormat.usd(bal))
        }
        return parts.joined(separator: " · ")
    }

    /// Claude `usage` shows one conventional active-constraint bar plus text for both windows.
    private static func claudeUsageLines(_ glance: QuotaGlance, nameWidth: Int, now: Date) -> [String] {
        let indent = pad("", to: nameWidth)
        let values = "5h \(glance.percent(for: .fiveHours)) · 7d \(glance.percent(for: .sevenDays))"
        guard let active = glance.active else { return ["\(indent)  \(values)"] }
        let account = active.accountName.map { "\($0) " } ?? ""
        let reset = active.resetsAt.map { "  \(resetsPhrase(until: $0, now: now))" } ?? ""
        return ["\(indent)  Active: \(account)\(active.period.rawValue) \(glance.percent(for: active.period))\(reset)", "\(indent)  \(values)"]
    }

    /// One aligned `name  pct  Resets …` row per window. Four Claude windows on a
    /// single ` · `-joined line wrapped and collided in the terminal.
    private static func windowLines(_ windows: [QuotaWindow], nameWidth: Int, now: Date) -> [String] {
        let labelWidth = windows.map(\.name.count).max() ?? 0
        return windows.map { w in
            "\(pad("", to: nameWidth))  \(windowCaption(w, labelWidth: labelWidth, now: now))"
        }
    }

    private static func windowCaption(_ w: QuotaWindow, labelWidth: Int, now: Date) -> String {
        let pct = w.utilization.map(CLIFormat.percent) ?? "—"
        let reset = w.resetsAt.map { resetsPhrase(until: $0, now: now) } ?? "—"
        return "\(pad(w.name, to: labelWidth))  \(pad(pct, to: 4))  \(reset)"
    }

    /// Multi-login Codex usage: label, one primary bar, primary reset. No cost.
    /// A missing primary fraction is `unavailable`, not the nil-quota "no limit" bar.
    private static func codexUsageAccountLines(
        _ account: UsageSnapshot.AccountUsage,
        nameWidth: Int,
        color: Bool,
        now: Date
    ) -> [String] {
        let indent = pad("", to: nameWidth)
        var lines = ["\(indent)    \(account.name)"]
        guard
            let primary = account.quotaWindows?.first(where: { $0.name == "primary" }),
            let used = primary.utilization
        else {
            lines.append("\(indent)  unavailable")
            return lines
        }
        let quota = Quota(used: used, limit: 1, remaining: max(0, 1 - used))
        lines.append("\(indent)  \(quotaBarLine(quota, color: color).0)")
        let reset = primary.resetsAt.map { resetsPhrase(until: $0, now: now) } ?? "Resets —"
        lines.append("\(indent)  \(reset)")
        return lines
    }

    /// Multi-login Codex quota: each login's primary and secondary windows under its label.
    private static func codexQuotaAccountLines(
        _ account: UsageSnapshot.AccountUsage,
        nameWidth: Int,
        now: Date
    ) -> [String] {
        let indent = pad("", to: nameWidth)
        var lines = ["\(indent)    \(account.name)"]
        if let windows = account.quotaWindows, !windows.isEmpty {
            lines.append(contentsOf: windowLines(windows, nameWidth: nameWidth, now: now))
        } else {
            lines.append("\(indent)  unavailable")
        }
        return lines
    }

    private static func accountLines(
        _ account: UsageSnapshot.AccountUsage,
        nameWidth: Int,
        color: Bool,
        now: Date
    ) -> [String] {
        let indent = pad("", to: nameWidth)
        var head = "  \(account.name)"
        if let cost = account.costTodayUSD {
            head += " · " + CLIFormat.usd(cost)
        }
        let glance = account.quotaGlance
        return ["\(indent)  \(head)", "\(indent)  \(claudeDualBarLine(glance))"]
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
        CLIFormat.resetsPhrase(until: date, now: now)
    }

    private static func pad(_ s: String, to n: Int) -> String {
        CLIFormat.pad(s, to: n)
    }
}

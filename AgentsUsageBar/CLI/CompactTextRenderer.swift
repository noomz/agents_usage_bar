import Foundation
import Darwin

/// `compact` CLI theme ("Compact v2"): a two-line header, then one line per
/// provider showing its most-used window, errors in place, and one `local`
/// line for local runtimes. Rules: SPEC V7–V22.
public enum CompactTextRenderer {

    /// Base column widths; the output width these produce is used when no
    /// terminal width is known (pipes, tests).
    public static let baseNameWidth = 12
    public static let baseBarWidth = 10
    static let minBarWidth = 5
    static let maxBarWidth = 20
    static let minNameWidth = 4

    /// Terminal width: `TIOCGWINSZ` on a TTY, else `$COLUMNS`, else `nil`.
    public static func terminalWidth(
        isTTY: Bool = isatty(STDOUT_FILENO) != 0,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        if isTTY {
            var size = winsize()
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
                return Int(size.ws_col)
            }
        }
        if let cols = environment["COLUMNS"].flatMap(Int.init), cols > 0 {
            return cols
        }
        return nil
    }

    /// - Parameters:
    ///   - width: available columns; `nil` renders at the base width.
    ///   - timeZone: zone for the header clock (tests pin UTC).
    public static func render(
        _ report: UsageReport,
        view: CLIView,
        color: Bool,
        width: Int?,
        timeZone: TimeZone = .current
    ) -> String {
        let providers = ordered(report.providers.filter { $0.status != .disabled })
        let remote = providers.filter { !$0.isLocal }
        let now = report.asOf

        var lines: [Line] = []
        for p in remote {
            lines.append(contentsOf: view == .usage ? usageLines(p, now: now) : quotaLines(p, now: now))
        }
        let local = view == .usage ? localItems(providers.filter(\.isLocal)) : []

        let layout = Layout.fit(lines, width: width)
        var out: [String] = []
        if view == .usage {
            out.append(headerTotals(report, timeZone: timeZone))
        }
        out.append(severityLine(lines))
        if report.providers.isEmpty {
            let message = report.source == .cached
                ? "no cached data yet — run aub without --cached"
                : "no providers enabled"
            out.append(dim(message, color: color))
        }
        out.append(contentsOf: lines.map { layout.render($0, color: color) })
        if !local.isEmpty {
            out.append(contentsOf: localLines(local, width: width ?? layout.totalWidth))
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Line model

    enum Severity: Equatable, Sendable {
        case normal, warning, critical

        init(_ fraction: Double?) {
            guard let f = fraction else { self = .normal; return }
            if f >= 0.80 { self = .critical } else if f >= 0.50 { self = .warning } else { self = .normal }
        }

        var glyph: Character {
            switch self {
            case .critical: "▲"
            case .warning: "△"
            case .normal: " "
            }
        }

        var band: QuotaBand {
            switch self {
            case .critical: .critical
            case .warning: .warning
            case .normal: .healthy
            }
        }
    }

    enum Gauge: Equatable {
        /// Consumed fraction drawn as a bar with a percent.
        case bar(Double)
        /// Text in the bar's place (`no limit`, `$1.25 spent`); never counted in the severity line.
        case text(String)
    }

    enum Line: Equatable {
        case row(name: String, gauge: Gauge, label: String, reset: String?, money: String?)
        case problem(name: String, word: String)
    }

    // MARK: - Header

    static func headerTotals(_ report: UsageReport, timeZone: TimeZone) -> String {
        let totals = report.totals
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "HH:mm"
        return "today \(CLIFormat.usd(totals.costUSD)) spent · \(siTokens(totals.tokens)) tok · \(clock.string(from: report.asOf))"
    }

    static func severityLine(_ lines: [Line]) -> String {
        var critical = 0, warning = 0, unavailable = 0
        for line in lines {
            switch line {
            case .row(_, .bar(let f), _, _, _):
                switch Severity(f) {
                case .critical: critical += 1
                case .warning: warning += 1
                case .normal: break
                }
            case .row: break
            case .problem: unavailable += 1
            }
        }
        return "\(critical) at ≥80% · \(warning) at 50–79% · \(unavailable) unavailable"
    }

    /// `232.4M`; below 1000 the plain count.
    static func siTokens(_ n: Int) -> String {
        let v = Double(n)
        switch v {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", v / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", v / 1_000_000)
        default: return String(format: "%.1fB", v / 1_000_000_000)
        }
    }

    // MARK: - Usage view rows

    static func usageLines(_ p: ProviderReport, now: Date) -> [Line] {
        let name = label(for: p)
        guard let snap = p.snapshot else {
            return [.problem(name: name, word: problemWord(p) ?? "unavailable")]
        }
        var lines: [Line]
        if p.id == .claude, let accounts = snap.accounts, !accounts.isEmpty {
            let active = snap.quotaGlance.active?.accountName
            lines = accounts.sorted { $0.name < $1.name }.enumerated().map { index, account in
                let mark = account.name == active ? "●" : ""
                let rowName = index == 0 ? "\(name) \(account.name)\(mark)" : "  \(account.name)\(mark)"
                let (gauge, windowLabel, reset) = claudeWindow(account.quotaGlance.active, now: now)
                return .row(name: rowName, gauge: gauge, label: windowLabel, reset: reset, money: spent(account.costTodayUSD))
            }
        } else {
            let (gauge, windowLabel, reset) = worstWindow(p, snap, now: now)
            lines = [.row(name: name, gauge: gauge, label: windowLabel, reset: reset, money: money(p, snap))]
        }
        if let word = problemWord(p) {
            lines.append(.problem(name: name, word: word))
        }
        return lines
    }

    /// Most-used window of a provider as (gauge, label, reset column).
    static func worstWindow(_ p: ProviderReport, _ snap: UsageSnapshot, now: Date) -> (Gauge, String, String?) {
        if p.id == .claude, snap.quotaGlance.hasAnyWindow {
            return claudeWindow(snap.quotaGlance.active, now: now)
        }
        if p.id == .openrouter {
            guard let q = snap.quota else { return (.text("no limit"), "", nil) }
            return (.bar(q.fraction), "credits", nil)
        }
        let windows = (snap.quotaWindows ?? []).filter { $0.utilization != nil }
        if let w = windows.max(by: { $0.utilization! < $1.utilization! }) {
            return (.bar(w.utilization!), windowLabel(w, p, snap), resetColumn(w.resetsAt, now: now))
        }
        if let q = snap.displayedQuota {
            return (.bar(q.fraction), "", nil)
        }
        return (.text("no limit"), "", nil)
    }

    static func claudeWindow(_ window: QuotaGlance.Window?, now: Date) -> (Gauge, String, String?) {
        guard let window, let u = window.utilization else { return (.text("no limit"), "", nil) }
        return (.bar(u), window.period.rawValue, resetColumn(window.resetsAt, now: now))
    }

    static func resetColumn(_ date: Date?, now: Date) -> String {
        "↻ " + (date.map { CLIFormat.resetCountdown(until: $0, now: now) } ?? "unknown")
    }

    /// Window label: length-derived (`5h`, `7d`) when known, Grok's billing
    /// period, else the provider's window name.
    static func windowLabel(_ w: QuotaWindow, _ p: ProviderReport, _ snap: UsageSnapshot) -> String {
        if let d = w.duration, d > 0 {
            let s = Int(d)
            if s % 86_400 == 0 { return "\(s / 86_400)d" }
            if s % 3_600 == 0 { return "\(s / 3_600)h" }
            return "\(max(1, s / 60))m"
        }
        if p.id == .grok, let period = snap.raw["period"], !period.isEmpty, period.count <= 10 {
            return period
        }
        return w.name
    }

    static func money(_ p: ProviderReport, _ snap: UsageSnapshot) -> String? {
        switch p.id {
        case .grok:
            return "no cost data"
        case .openrouter:
            var parts: [String] = []
            if let balance = snap.balanceUSD { parts.append("\(CLIFormat.usd(balance)) left") }
            if let day = snap.periodSpendUSD?.day { parts.append("\(CLIFormat.usd(day)) today") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        default:
            return spent(snap.costTodayUSD)
        }
    }

    static func spent(_ cost: Decimal?) -> String? {
        cost.map { "\(CLIFormat.usd($0)) spent" }
    }

    /// Word for a provider in trouble, `nil` when healthy (V17).
    static func problemWord(_ p: ProviderReport) -> String? {
        let degraded = p.snapshot?.raw["note"] == ThresholdEngine.degradedTag
        switch p.status {
        case .unauthenticated: return "unauthenticated"
        case .stale: return "stale"
        case .error, .notRunning: return "unavailable"
        case .ok, .disabled: return degraded || p.snapshot == nil ? "unavailable" : nil
        }
    }

    // MARK: - Quota view rows

    static func quotaLines(_ p: ProviderReport, now: Date) -> [Line] {
        let name = label(for: p)
        guard let snap = p.snapshot else {
            return [.problem(name: name, word: problemWord(p) ?? "unavailable")]
        }
        var rows: [(name: String, gauge: Gauge, label: String, reset: String?)] = []
        if p.id == .claude, let accounts = snap.accounts, !accounts.isEmpty {
            let active = snap.quotaGlance.active?.accountName
            for (index, account) in accounts.sorted(by: { $0.name < $1.name }).enumerated() {
                let mark = account.name == active ? "●" : ""
                let head = index == 0 ? "\(name) \(account.name)\(mark)" : "  \(account.name)\(mark)"
                let glance = account.quotaGlance
                for (i, window) in [glance.fiveHours, glance.sevenDays].compactMap({ $0 }).enumerated() {
                    let (gauge, windowLabel, reset) = claudeWindow(window, now: now)
                    rows.append((i == 0 ? head : "", gauge, windowLabel, reset))
                }
            }
        } else if p.id == .claude, snap.quotaGlance.hasAnyWindow {
            let glance = snap.quotaGlance
            for window in [glance.fiveHours, glance.sevenDays].compactMap({ $0 }) {
                let (gauge, windowLabel, reset) = claudeWindow(window, now: now)
                rows.append((rows.isEmpty ? name : "", gauge, windowLabel, reset))
            }
        } else if p.id == .openrouter {
            let (gauge, windowLabel, reset) = worstWindow(p, snap, now: now)
            rows.append((name, gauge, windowLabel, reset))
            if let spend = snap.periodSpendUSD {
                for (period, amount) in [("day", spend.day), ("week", spend.week), ("month", spend.month)] {
                    rows.append(("", .text("\(CLIFormat.usd(amount)) spent"), period, nil))
                }
            }
        } else if let windows = snap.quotaWindows, !windows.isEmpty {
            for w in windows {
                let gauge: Gauge = w.utilization.map { .bar($0) } ?? .text("no limit")
                rows.append((rows.isEmpty ? name : "", gauge, windowLabel(w, p, snap), resetColumn(w.resetsAt, now: now)))
            }
        } else {
            let (gauge, windowLabel, reset) = worstWindow(p, snap, now: now)
            rows.append((name, gauge, windowLabel, reset))
        }
        var lines = rows.map { Line.row(name: $0.name, gauge: $0.gauge, label: $0.label, reset: $0.reset, money: nil) }
        if let word = problemWord(p) {
            lines.append(.problem(name: name, word: word))
        }
        return lines
    }

    // MARK: - Local line

    static func localItems(_ locals: [ProviderReport]) -> [String] {
        locals.compactMap { p in
            if let msg = p.placeholderMessage, !msg.isEmpty { return nil }
            let name = label(for: p)
            let raw = p.snapshot?.raw ?? [:]
            if raw["loadingModel"] == "true" { return "◐ \(name) loading" }
            switch p.status {
            case .notRunning: return "○ \(name) stopped"
            case .ok:
                let count = Int(raw["modelCount"] ?? "") ?? 0
                guard count > 0 else { return "○ \(name) idle" }
                let model = raw["modelName"].map { " \($0)" } ?? ""
                return "● \(name)\(model)" + (count > 1 ? " +\(count - 1)" : "")
            default: return "○ \(name) unavailable"
            }
        }
    }

    /// `  local ` then items two spaces apart, wrapping onto indented lines.
    static func localLines(_ items: [String], width: Int) -> [String] {
        let prefix = "  local "
        let indent = String(repeating: " ", count: prefix.count)
        var lines: [String] = []
        var current = prefix
        for item in items {
            let fresh = current == prefix || current == indent
            let candidate = fresh ? current + item : current + "  " + item
            if !fresh, candidate.count > width {
                lines.append(current)
                current = indent + item
            } else {
                current = candidate
            }
        }
        lines.append(current)
        return lines
    }

    // MARK: - Labels and order

    static let shortLabels: [ProviderID: String] = [
        .openrouter: "OpenRouter", .claude: "Claude", .codex: "Codex", .gemini: "Gemini",
        .grok: "Grok", .ollama: "Ollama", .lmstudio: "LM Studio", .llamacpp: "llama.cpp",
    ]

    static func label(for p: ProviderReport) -> String {
        shortLabels[p.id] ?? p.displayName
    }

    /// Known-provider order, then custom `engine.*` rows by slug.
    static func ordered(_ providers: [ProviderReport]) -> [ProviderReport] {
        func key(_ id: ProviderID) -> (Int, String) {
            (ProviderID.allKnown.firstIndex(of: id) ?? ProviderID.allKnown.count, id.rawValue)
        }
        return providers.sorted { key($0.id) < key($1.id) }
    }

    static func dim(_ text: String, color: Bool) -> String {
        color ? "\u{001B}[2m\(text)\(CLIFormat.ansiReset)" : text
    }

    // MARK: - Layout

    /// Column widths for one render, fitted to the available width (V19).
    struct Layout {
        var nameWidth: Int
        var barWidth: Int
        let labelWidth: Int
        let resetWidth: Int
        let moneyWidth: Int

        /// Bar cells + space + right-aligned percent.
        var gaugeWidth: Int { barWidth + 5 }

        var totalWidth: Int { width(name: nameWidth, bar: barWidth) }

        func width(name: Int, bar: Int) -> Int {
            var w = 2 + name + 1 + bar + 5
            if labelWidth > 0 { w += 1 + labelWidth }
            if resetWidth > 0 { w += 1 + resetWidth }
            if moneyWidth > 0 { w += 2 + moneyWidth }
            return w
        }

        static func fit(_ lines: [Line], width: Int?) -> Layout {
            var names: [String] = [], labels = [0], resets = [0], money = [0], texts = [0]
            for line in lines {
                switch line {
                case let .row(name, gauge, label, reset, m):
                    names.append(name)
                    labels.append(label.count)
                    resets.append(reset?.count ?? 0)
                    money.append(m?.count ?? 0)
                    if case .text(let t) = gauge { texts.append(t.count) }
                case let .problem(name, _):
                    names.append(name)
                }
            }
            let longestName = names.map(\.count).max() ?? 0
            // Text gauges (`$31.40 spent`) must fit where the bar and percent go.
            let barFloor = max(minBarWidth, (texts.max() ?? 0) - 5)
            var layout = Layout(
                nameWidth: baseNameWidth,
                barWidth: max(baseBarWidth, barFloor),
                labelWidth: labels.max() ?? 0,
                resetWidth: resets.max() ?? 0,
                moneyWidth: money.max() ?? 0
            )
            guard let width else { return layout }
            if width > layout.totalWidth {
                var extra = width - layout.totalWidth
                let grow = min(extra, max(0, longestName - layout.nameWidth))
                layout.nameWidth += grow
                extra -= grow
                layout.barWidth = min(maxBarWidth, layout.barWidth + extra)
            } else {
                while layout.totalWidth > width, layout.barWidth > barFloor {
                    layout.barWidth -= 1
                }
                while layout.totalWidth > width, layout.nameWidth > minNameWidth {
                    layout.nameWidth -= 1
                }
            }
            return layout
        }

        func render(_ line: Line, color: Bool) -> String {
            switch line {
            case let .problem(name, word):
                let text = "! \(fitName(name)) \(word)"
                return CLIFormat.paint(text, band: .critical, color: color)
            case let .row(name, gauge, label, reset, money):
                var out = ""
                switch gauge {
                case .bar(let fraction):
                    let severity = Severity(fraction)
                    let (fill, track) = CLIFormat.eighthBar(consumed: fraction, width: barWidth)
                    let glyph = CLIFormat.paint(String(severity.glyph), band: severity.band, color: color)
                    let pct = CLIFormat.percent(fraction)
                    out = "\(glyph) \(fitName(name)) "
                        + CLIFormat.paint(fill, band: severity.band, color: color)
                        + CLIFormat.paint(track, band: .none, color: color)
                        + " " + String(repeating: " ", count: max(0, 4 - pct.count)) + pct
                case .text(let text):
                    out = "  \(fitName(name)) " + CLIFormat.paint(CLIFormat.pad(text, to: gaugeWidth), band: .none, color: color)
                }
                if labelWidth > 0 { out += " " + CLIFormat.pad(label, to: labelWidth) }
                if resetWidth > 0 { out += " " + CLIFormat.pad(reset ?? "", to: resetWidth) }
                if moneyWidth > 0, let money {
                    out += "  " + String(repeating: " ", count: max(0, moneyWidth - money.count)) + money
                }
                return out.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
        }

        func fitName(_ name: String) -> String {
            if name.count <= nameWidth { return CLIFormat.pad(name, to: nameWidth) }
            return String(name.prefix(nameWidth - 1)) + "…"
        }
    }
}

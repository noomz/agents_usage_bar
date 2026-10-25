import Foundation

/// `aub stats` text: the provider summary and the per-day drill-down (SPEC V42–V46). One
/// layout for every theme, with the compact palette, glyphs, and severity colours.
public enum StatsTextRenderer {

    public static let noHistory = "No history yet. The app records from first launch; backfill runs in the background"

    /// Bare `aub stats`: one row per provider, then a total of metered spend, then one line
    /// per configured budget with this month's spend from `monthDays` (V42, V43).
    public static func renderSummary(
        _ days: [DayFile],
        range: StatsRange,
        includeLocal: Bool,
        order: [ProviderID] = [],
        budgets: BudgetConfig = .none,
        monthDays: [DayFile] = [],
        color: Bool
    ) -> String {
        let providers = ProviderStats.collect(days, range: range, includeLocal: includeLocal, order: order)
        var out = [header(range, bucketed: true)]
        guard !providers.isEmpty else {
            out.append("No history in this range.")
            return out.joined(separator: "\n") + "\n"
        }
        var legend = Legend()
        var rows: [[Cell]] = [[.dim("provider"), .dim("spend"), .dim("tokens", right: true), .dim("peak"),
                               .dim("days", right: true), .dim("trend")]]
        for p in providers {
            let days = Cell("\(p.seenDays)/\(range.keys.count)", right: true)
            let trend = trendCell(p, bucketSize: range.bucketSize, legend: &legend)
            if p.kind == .local {
                rows.append([Cell(name(p.id)), .dim("used \(p.seenDays)/\(range.keys.count) days"), Cell(""),
                             Cell(""), days, trend])
                continue
            }
            rows.append([Cell(name(p.id)), spendCell(p, legend: &legend),
                         Cell(p.tokens.map(CompactTextRenderer.siTokens) ?? "", right: true),
                         peakCell(p.peak), days, trend])
        }
        rows.append(totalRow(providers.filter(\.hasSpend), legend: &legend))
        out.append(contentsOf: table(rows, color: color))
        out.append(contentsOf: budgetLines(budgets, monthDays: monthDays, today: range.today, legend: &legend))
        out.append(contentsOf: legend.line(color: color))
        return out.joined(separator: "\n") + "\n"
    }

    /// `aub stats <provider>`: one row per day (V44). A local runtime shows presence.
    public static func renderProvider(
        _ days: [DayFile],
        id: ProviderID,
        range: StatsRange,
        color: Bool
    ) -> String {
        guard let p = ProviderStats.collect(days, range: range, includeLocal: true, only: id).first else {
            return header(range, bucketed: false) + "\nNo \(name(id)) history in this range.\n"
        }
        let byKey = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        var legend = Legend()
        var out = ["\(name(id)) · " + header(range, bucketed: false)]
        if p.kind == .local {
            out[0] += " · used \(p.seenDays)/\(range.keys.count) days"
        }

        let money: [(title: String, column: KeyPath<DayCostSplit, Money?>, isValue: Bool)] =
            switch p.kind {
            case .metered: [("spend", \.spend, false)]
            case .subscription: [("value", \.value, true)]
            case .mixed: [("spend", \.spend, false), ("value", \.value, true)]
            case .local: []
            }
        var rows: [[Cell]] = [
            [.dim("date")] + (p.kind == .local ? [.dim("used")] : money.map { .dim($0.title, right: true) })
                + (p.kind == .local ? [] : [.dim("tokens", right: true), .dim("peak"), .dim("events"), .dim("markers")]),
        ]
        for (key, record) in zip(range.keys, p.records) {
            guard let record else {
                legend.gap = true
                rows.append([Cell(key), .dim("·")])
                continue
            }
            if p.kind == .local {
                rows.append([Cell(key), Cell("used")])
                continue
            }
            let split = record.costSplit
            var markers: [String] = []
            var cells = [Cell(key)]
            for column in money {
                let applies = column.isValue ? split.hasSubscription : split.hasMetered
                guard applies else {
                    cells.append(Cell("", right: true))
                    continue
                }
                guard let amount = split[keyPath: column.column] else {
                    cells.append(Cell("?", right: true))
                    if !markers.contains("!") { markers.append("!") }
                    legend.incomplete = true
                    continue
                }
                let estimated = column.isValue || split.estimated
                if estimated { legend.estimated = true }
                let text = (estimated ? "~" : "") + CLIFormat.usd(amount.amount)
                cells.append(column.isValue ? .dim(text, right: true) : Cell(text, right: true))
            }
            if record.origin == .backfilled { markers.append("backfilled") }
            if key == range.today { markers.append("open") }
            let events = byKey[key]?.events.filter { $0.provider == id }.map(eventLabel) ?? []
            cells += [Cell(record.tokens.map(CompactTextRenderer.siTokens) ?? "", right: true),
                      peakCell(ProviderStats.peak(record)),
                      Cell(events.joined(separator: ", ")),
                      Cell(markers.joined(separator: " "))]
            rows.append(cells)
        }
        if p.kind != .local {
            var total = [Cell("total")]
            for column in money {
                total.append(totalCell(column.isValue ? p.value : p.spend, isValue: column.isValue, legend: &legend))
            }
            total.append(Cell(p.tokens.map(CompactTextRenderer.siTokens) ?? "", right: true))
            rows.append(total)
        }
        out.append(contentsOf: table(rows, color: color))
        out.append(contentsOf: legend.line(color: color))
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Cells

    static func header(_ range: StatsRange, bucketed: Bool) -> String {
        var text = "\(range.keys[0]) – \(range.keys[range.keys.count - 1]) · \(range.keys.count) days"
        if range.isTodayOpen { text += " (today open)" }
        if bucketed, range.bucketSize > 1 { text += " · trend 1 char = \(range.bucketSize) days" }
        return text
    }

    static func name(_ id: ProviderID) -> String {
        CompactTextRenderer.shortLabels[id] ?? id.displayHint
    }

    /// Spend for metered rows, the plan name dimmed for subscription rows, and metered spend
    /// plus `+plan` for mixed rows (V43). Value never shows here (V26).
    static func spendCell(_ p: ProviderStats, legend: inout Legend) -> Cell {
        let plans = p.plans.isEmpty ? "subscription" : p.plans.joined(separator: "/")
        switch p.kind {
        case .subscription:
            return .dim(plans)
        case .mixed:
            return Cell(segments: [(amountText(p.spend, legend: &legend), .plain), (" +" + plans, .dim)])
        case .metered, .local:
            return Cell(amountText(p.spend, legend: &legend))
        }
    }

    /// The summary's total row: metered spend only (V42).
    static func totalRow(_ metered: [ProviderStats], legend: inout Legend) -> [Cell] {
        guard !metered.isEmpty else {
            return [Cell("total"), Cell(segments: [(CLIFormat.usd(0), .plain), (" no metered accounts", .dim)])]
        }
        var sum = ProviderStats.Total()
        for p in metered { sum.add(p.spend) }
        return [Cell("total"), Cell(amountText(sum, legend: &legend))]
    }

    static func totalCell(_ total: ProviderStats.Total, isValue: Bool, legend: inout Legend) -> Cell {
        var total = total
        total.estimated = total.estimated || isValue
        let text = amountText(total, legend: &legend)
        return isValue ? .dim(text, right: true) : Cell(text, right: true)
    }

    /// `~` before an estimated amount, `!` after an incomplete one, `?` when nothing is
    /// known (V45). Unknown is never shown as zero (V7).
    static func amountText(_ total: ProviderStats.Total, legend: inout Legend) -> String {
        guard let amount = total.amount else {
            legend.incomplete = true
            return "?!"
        }
        if total.estimated { legend.estimated = true }
        if total.incomplete { legend.incomplete = true }
        return (total.estimated ? "~" : "") + CLIFormat.usd(amount) + (total.incomplete ? "!" : "")
    }

    /// `92% 5h`, coloured by the existing severity bands (V43).
    static func peakCell(_ peak: (fraction: Double, window: String)?) -> Cell {
        guard let peak else { return Cell("") }
        let window = peak.window == UsageSnapshot.providerQuotaWindow ? "" : " " + peak.window
        let band = CompactTextRenderer.Severity(peak.fraction).band
        return Cell(segments: [(CLIFormat.percent(peak.fraction) + window, .band(band))])
    }

    static let sparks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    /// `$` then spend scaled to the row's highest bucket, `%` then the quota peak on an
    /// absolute scale, or presence for a local row (V43). `·` is a gap, `!` a bucket
    /// holding one (V44, V45).
    static func trendCell(_ p: ProviderStats, bucketSize: Int, legend: inout Legend) -> Cell {
        let cells = p.trend(bucketSize: bucketSize)
        let top = cells.compactMap { cell -> Double? in if case .value(let v) = cell { v } else { nil } }.max() ?? 0
        var segments: [(String, Style)] = [(p.kind == .metered ? "$" : p.kind == .local ? " " : "%", .dim)]
        for cell in cells {
            switch cell {
            case .value(let v):
                let level = p.kind == .metered ? (top > 0 ? v / top : 0) : v
                let index = level <= 0 ? 0 : min(sparks.count - 1, Int((level * Double(sparks.count)).rounded(.up)) - 1)
                segments.append((String(sparks[index]), .plain))
            case .present:
                segments.append(("█", .plain))
            case .gap:
                legend.gap = true
                segments.append(("·", .dim))
            case .noValue:
                legend.noValue = true
                segments.append(("?", .dim))
            case .incomplete:
                legend.incomplete = true
                segments.append(("!", .plain))
            }
        }
        return Cell(segments: segments)
    }

    static func eventLabel(_ event: UsageEvent) -> String {
        let kind = switch event.kind {
        case .band80: "80%"
        case .band95: "95%"
        case .band100: "100%"
        case .pace: "pace"
        case .reset: "reset"
        case .authLost: "auth lost"
        case .authRecovered: "auth back"
        case .budgetWarning: "budget"
        case .budgetLimit: "budget 100%"
        }
        return event.window.map { "\(kind) \($0)" } ?? kind
    }

    /// `Oct spend $11.40 / $50.00 budget`, the total first, then each provider budget (V42).
    static func budgetLines(_ budgets: BudgetConfig, monthDays: [DayFile], today: String, legend: inout Legend) -> [String] {
        let month = monthLabel(today)
        return BudgetScope.all.compactMap { scope in
            guard let cap = budgets.caps[scope] else { return nil }
            let spend = SpendTotal.month(monthDays, today: today, scope: scope)
            let prefix = scope.providerID.map { name($0) + " " } ?? ""
            return "\(prefix)\(month) spend \(amountText(spend, legend: &legend)) / \(CLIFormat.usd(cap.amount)) budget"
        }
    }

    /// The month of a day key, named by the system calendar and locale (V2).
    static func monthLabel(_ key: String) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: 15))
        else { return key }
        let formatter = DateFormatter()
        formatter.timeZone = gregorian.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: date)
    }

    // MARK: - Legend

    /// Markers seen while rendering; the legend lists only these (V45).
    struct Legend {
        var estimated = false
        var gap = false
        var noValue = false
        var incomplete = false

        func line(color: Bool) -> [String] {
            let entries = [(estimated, "~ estimated"), (gap, "· gap"), (noValue, "? no value"), (incomplete, "! incomplete")]
                .filter(\.0).map(\.1)
            guard !entries.isEmpty else { return [] }
            return [CompactTextRenderer.dim(entries.joined(separator: "  "), color: color)]
        }
    }

    // MARK: - Table

    enum Style {
        case plain, dim
        case band(QuotaBand)
    }

    struct Cell {
        var segments: [(String, Style)]
        var right = false

        init(_ text: String, right: Bool = false) {
            self.segments = [(text, .plain)]
            self.right = right
        }

        init(segments: [(String, Style)], right: Bool = false) {
            self.segments = segments
            self.right = right
        }

        static func dim(_ text: String, right: Bool = false) -> Cell {
            Cell(segments: [(text, .dim)], right: right)
        }

        var width: Int { segments.reduce(0) { $0 + $1.0.count } }

        func painted(color: Bool) -> String {
            segments.map { text, style in
                switch style {
                case .plain: text
                case .dim: CompactTextRenderer.dim(text, color: color && !text.isEmpty)
                case .band(let band): CLIFormat.paint(text, band: band, color: color)
                }
            }.joined()
        }
    }

    /// Columns two spaces apart, padded outside the ANSI spans; trailing space trimmed.
    static func table(_ rows: [[Cell]], color: Bool) -> [String] {
        let columns = rows.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in
            rows.map { column < $0.count ? $0[column].width : 0 }.max() ?? 0
        }
        return rows.map { row in
            var line = ""
            for (column, cell) in row.enumerated() {
                let pad = String(repeating: " ", count: widths[column] - cell.width)
                if column > 0 { line += "  " }
                line += cell.right ? pad + cell.painted(color: color) : cell.painted(color: color) + pad
            }
            while line.last == " " { line.removeLast() }
            return line
        }
    }
}

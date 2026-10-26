import Charts
import SwiftUI

/// Provider detail (SPEC V54): tabs named by billing model, Tokens, Quota, and Accounts, a
/// large chart above the usage event table, and an account picker that narrows every tab.
/// The range is the shared one on the model (V52). Markers follow V56.
struct DashboardProviderDetailView: View {
    typealias Detail = DashboardProviderDetail

    @Bindable var model: DashboardModel
    let id: ProviderID
    @State private var tab: Detail.Tab = .cost
    @State private var account: String?

    var body: some View {
        let detail = Detail(id: id, days: model.days, range: model.range.statsRange(today: model.today), account: account)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                title(detail)
                DashboardRangeHeader(model: model)
                if detail.stats.seenDays == 0 {
                    Text("No records for \(id.displayHint) in this range.")
                        .foregroundStyle(.secondary)
                } else {
                    tiles(detail)
                    Picker("View", selection: $tab) {
                        ForEach(Detail.Tab.allCases, id: \.self) { Text(tabTitle($0, detail)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 440)
                    chart(detail)
                    DashboardSection("Usage events") { eventTable(detail) }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Header and tiles

    private func title(_ detail: Detail) -> some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(id.displayHint).font(.title2.bold())
            Spacer()
            if detail.accounts.count > 1 {
                Picker("Account", selection: Binding(get: { detail.account }, set: { account = $0 })) {
                    Text("All accounts").tag(String?.none)
                    ForEach(detail.accounts) { account in
                        Text(accountName(account)).tag(String?.some(account.key))
                    }
                }
                .frame(maxWidth: 240)
            }
        }
    }

    private func tiles(_ detail: Detail) -> some View {
        let stats = detail.stats
        let tokens = detail.tokens
        return HStack(alignment: .top, spacing: 12) {
            if stats.hasSpend {
                DashboardTile(
                    title: "Spend", value: dashboardTotal(stats.spend, approximate: stats.spend.estimated),
                    note: stats.spend.estimated ? "includes estimated" : nil, incomplete: stats.spend.incomplete)
            }
            if stats.hasValue {
                DashboardTile(
                    title: "Value", value: dashboardTotal(stats.value, approximate: true),
                    note: "API-equivalent, not spend", incomplete: stats.value.incomplete, dimmed: true)
            }
            if stats.kind == .local {
                DashboardTile(title: "Days seen", value: "\(stats.seenDays)/\(detail.range.keys.count)")
            }
            if let total = tokens.total {
                DashboardTile(
                    title: "Tokens", value: total.formatted(.number.notation(.compactName)), incomplete: tokens.incomplete)
            }
            if let peak = stats.peak {
                DashboardTile(title: "Peak quota", value: "\(Int((peak.fraction * 100).rounded()))% \(peak.window)")
            }
            DashboardTile(
                title: "Usage events", value: "\(detail.events.count)",
                note: "\(detail.events.count { !$0.notified }) not notified")
        }
    }

    private func tabTitle(_ tab: Detail.Tab, _ detail: Detail) -> String {
        switch tab {
        case .cost: return detail.costTabTitle
        case .tokens: return "Tokens"
        case .quota: return "Quota"
        case .accounts: return "Accounts"
        }
    }

    private func accountName(_ account: Detail.Account) -> String {
        account.plan.map { $0 == account.label ? account.label : "\(account.label) · \($0)" } ?? account.label
    }

    private var color: Color { DashboardPalette.color(id) }

    // MARK: - Charts

    @ViewBuilder
    private func chart(_ detail: Detail) -> some View {
        switch tab {
        case .cost:
            if detail.stats.kind == .local { presenceChart(detail) } else { costChart(detail) }
        case .tokens:
            tokenChart(detail)
        case .quota:
            quotaCharts(detail)
        case .accounts:
            accountsView(detail)
        }
    }

    private func day(_ key: String) -> PlottableValue<Date> {
        .value("Day", DashboardRange.date(forKey: key), unit: .day)
    }

    private func gapBands(_ detail: Detail) -> some ChartContent {
        ForEach(detail.gapKeys, id: \.self) { key in
            RectangleMark(x: day(key)).foregroundStyle(.gray.opacity(0.15))
        }
    }

    /// Spend solid, value hatched, side by side and never stacked or summed (V26, V54).
    @ViewBuilder
    private func costChart(_ detail: Detail) -> some View {
        let points = detail.costPoints
        if points.isEmpty {
            DashboardNote(detail.account == nil ? "No known cost in this range." : "This account's cost is not reported on its own.")
        } else {
            Chart {
                gapBands(detail)
                ForEach(points) { point in
                    BarMark(x: day(point.key), y: .value("Amount", point.amount))
                        .position(by: .value("Series", point.series.rawValue))
                        .foregroundStyle(point.series == .spend ? AnyShapeStyle(color) : AnyShapeStyle(DashboardPalette.hatch(color)))
                        .opacity(point.estimated || point.backfilled ? 0.55 : 1)
                }
            }
            .chartXScale(domain: detail.range.chartDomain)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(amount, format: .currency(code: "USD")) }
                    }
                }
            }
            .frame(height: 260)
            DashboardNote(costNote(detail))
        }
    }

    private func costNote(_ detail: Detail) -> String {
        var parts: [String] = []
        if detail.stats.hasSpend && detail.stats.hasValue { parts.append("solid = spend · hatched = value (~$, never added to spend)") }
        parts.append("lighter = estimated (~$) or backfilled · grey band = no data")
        return parts.joined(separator: " · ")
    }

    /// Local runtimes show the days they were seen, never $0 (V56).
    private func presenceChart(_ detail: Detail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                gapBands(detail)
                ForEach(Array(zip(detail.range.keys, detail.stats.records)), id: \.0) { key, record in
                    if record != nil {
                        RectangleMark(x: day(key)).foregroundStyle(color.opacity(0.7))
                    }
                }
            }
            .chartXScale(domain: detail.range.chartDomain)
            .chartYAxis(.hidden)
            .frame(height: 60)
            DashboardNote("no cost data · coloured = seen · grey band = not seen")
        }
    }

    @ViewBuilder
    private func tokenChart(_ detail: Detail) -> some View {
        let points = detail.tokenPoints
        if points.isEmpty {
            DashboardNote(detail.account == nil ? "No token data in this range." : "Tokens are not reported per account here.")
        } else {
            Chart {
                gapBands(detail)
                ForEach(points) { point in
                    BarMark(x: day(point.key), y: .value("Tokens", point.tokens))
                        .foregroundStyle(color)
                        .opacity(point.backfilled ? 0.55 : 1)
                }
            }
            .chartXScale(domain: detail.range.chartDomain)
            .frame(height: 260)
            DashboardNote("lighter = backfilled · grey band = no data")
        }
    }

    /// One chart per window: a bar from end of day up to the peak, coloured by peak band (V54).
    @ViewBuilder
    private func quotaCharts(_ detail: Detail) -> some View {
        let windows = detail.quotaWindows
        if windows.isEmpty {
            DashboardNote("No quota recorded in this range. Backfilled days carry no quota.")
        } else {
            ForEach(windows, id: \.self) { window in
                let bars = detail.quotaBars(window)
                DashboardSection(window) {
                    Chart {
                        gapBands(detail)
                        ForEach(bars) { bar in
                            BarMark(x: day(bar.key), yStart: .value("End of day", bar.endOfDay), yEnd: .value("Peak", bar.peak))
                                .foregroundStyle(DashboardPalette.band(DashboardQuotaCell.band(peak: bar.peak)))
                            PointMark(x: day(bar.key), y: .value("Peak", bar.peak))
                                .foregroundStyle(DashboardPalette.band(DashboardQuotaCell.band(peak: bar.peak)))
                                .symbolSize(16)
                        }
                    }
                    .chartXScale(domain: detail.range.chartDomain)
                    .chartYScale(domain: 0...max(1, bars.map(\.peak).max() ?? 1))
                    .chartYAxis {
                        AxisMarks(values: [0, 0.5, 0.8, 1]) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let fraction = value.as(Double.self) { Text(fraction, format: .percent) }
                            }
                        }
                    }
                    .frame(height: 160)
                }
            }
            DashboardNote("bar = end of day → peak · colour = peak band (under 80% · 80% · 95% · 100%) · grey band = no data")
        }
    }

    private func accountsView(_ detail: Detail) -> some View {
        let accounts = detail.shownAccounts
        return VStack(alignment: .leading, spacing: 12) {
            Chart {
                gapBands(detail)
                ForEach(accounts) { account in
                    ForEach(Array(zip(detail.range.keys, account.stats.records)), id: \.0) { key, record in
                        if record != nil {
                            RectangleMark(x: day(key), y: .value("Account", accountName(account)), height: 14)
                                .foregroundStyle(by: .value("Billing", account.billingModel.rawValue))
                        }
                    }
                }
            }
            .chartXScale(domain: detail.range.chartDomain)
            .frame(height: CGFloat(50 + 26 * accounts.count))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Account"); Text("Billing"); Text("Spend"); Text("Value"); Text("Peak"); Text("Days")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(accounts) { account in
                    let stats = account.stats
                    GridRow {
                        Text(accountName(account))
                        Text(account.billingModel.rawValue)
                        Text(stats.hasSpend ? dashboardTotal(stats.spend, approximate: stats.spend.estimated) : "")
                        Text(stats.hasValue ? dashboardTotal(stats.value, approximate: true) : "")
                            .foregroundStyle(.secondary)
                        Text(stats.peak.map { "\(Int(($0.fraction * 100).rounded()))% \($0.window)" } ?? "")
                        Text("\(stats.seenDays)/\(detail.range.keys.count)")
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }

    // MARK: - Events

    @ViewBuilder
    private func eventTable(_ detail: Detail) -> some View {
        if detail.events.isEmpty {
            DashboardNote("No usage events in this range.")
        } else {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Time"); Text("Kind"); Text("Window"); Text("Notified"); Text("Carried over")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(Array(detail.events.enumerated()), id: \.offset) { _, event in
                    GridRow {
                        Text(event.time.formatted(date: .abbreviated, time: .shortened))
                        Label(DashboardPalette.title(event.kind), systemImage: DashboardPalette.symbol(event.kind))
                        Text(event.window ?? "")
                        Text(event.notified ? "yes" : "no").foregroundStyle(event.notified ? .primary : .secondary)
                        Text(event.carriedOver ? "yes" : "")
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }
}

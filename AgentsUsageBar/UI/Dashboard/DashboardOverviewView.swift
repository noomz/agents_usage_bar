import Charts
import SwiftUI

/// The Overview section (SPEC V53): tiles, month budget bars, spend per day stacked by
/// provider (metered only), an event lane, a quota band strip, and tokens per day. The range
/// and provider chips are shared state on the model. Markers follow V56. "Split accounts"
/// breaks spend per day, the quota strip, and tokens per day into accounts (V68).
struct DashboardOverviewView: View {
    @Bindable var model: DashboardModel
    let budgets: [DashboardBudget]
    let warningFraction: Double

    var body: some View {
        let overview = model.overview
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DashboardRangeHeader(model: model)
                HStack {
                    chips
                    Spacer()
                    Toggle("Split accounts", isOn: $model.splitAccounts)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                tiles(overview)
                if !budgets.isEmpty { budgetSection }
                DashboardSection("Spend per day") { spendChart(overview) }
                if !overview.events.isEmpty {
                    DashboardSection("Usage events") { eventLane(overview) }
                }
                if !overview.quotaRows.isEmpty {
                    DashboardSection("Quota peak per day") { quotaStrip(overview) }
                }
                if !overview.tokensPerDay.isEmpty {
                    DashboardSection("Tokens per day") { tokenChart(overview) }
                }
                DashboardSection("By provider") { providerList(overview) }
            }
            .padding(20)
        }
    }

    // MARK: - Header, chips, tiles

    /// One chip per provider with a record in range (V53).
    private var chips: some View {
        DashboardChips(model: model, ids: DashboardOverview(
            days: model.days, range: model.range.statsRange(today: model.today), order: model.order
        ).providers.map(\.id))
    }

    private func tiles(_ overview: DashboardOverview) -> some View {
        HStack(alignment: .top, spacing: 12) {
            spendTile(overview)
            if let value = overview.value {
                DashboardTile(title: "Subscription value", value: dashboardTotal(value, approximate: true), note: "API-equivalent, not spend",
                     incomplete: value.incomplete, dimmed: true)
            }
            DashboardTile(title: "Tokens", value: overview.tokens.map { $0.formatted(.number.notation(.compactName)) } ?? "—")
            DashboardTile(title: "Usage events", value: "\(overview.events.count)", note: "\(overview.notNotifiedCount) not notified")
        }
    }

    private func spendTile(_ overview: DashboardOverview) -> some View {
        if overview.spendProviders.isEmpty {
            return DashboardTile(title: "Spend", value: dashboardUSD(0), note: "no metered accounts")
        }
        let spend = overview.spend
        return DashboardTile(title: "Spend", value: dashboardTotal(spend, approximate: spend.estimated), note: spend.estimated ? "includes estimated" : nil,
                    incomplete: spend.incomplete)
    }

    private var budgetSection: some View {
        let month = DashboardRange.date(forKey: model.today).formatted(.dateTime.month(.wide).year())
        return DashboardSection("Budgets · \(month)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(budgets) { budget in
                    DashboardBudgetBar(
                        label: budget.scope.providerID?.displayHint ?? "Total", budget: budget,
                        warningFraction: warningFraction)
                }
            }
            .frame(maxWidth: 480)
        }
    }

    // MARK: - Charts

    @ViewBuilder
    private func spendChart(_ overview: DashboardOverview) -> some View {
        if overview.spendProviders.isEmpty {
            Text("No metered spend — subscription usage shown as value and quota below.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(overview.spendGapKeys, id: \.self) { key in
                    RectangleMark(x: .value("Day", DashboardRange.date(forKey: key), unit: .day))
                        .foregroundStyle(.gray.opacity(0.15))
                }
                ForEach(overview.spendPerDay) { day in
                    BarMark(
                        x: .value("Day", DashboardRange.date(forKey: day.key), unit: .day),
                        y: .value("Spend", day.amount))
                        .foregroundStyle(by: .value("Provider", overview.seriesName(day.provider, day.part)))
                        .opacity(day.estimated || day.backfilled ? 0.55 : 1)
                }
            }
            .chartForegroundStyleScale(domain: spendScale(overview).domain, range: spendScale(overview).range)
            .chartXScale(domain: overview.range.chartDomain)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(amount, format: .currency(code: "USD")) }
                    }
                }
            }
            .frame(height: 200)
            DashboardNote(
                (overview.splitAccounts.isEmpty ? "" : "split by account · unattributed = spend no single account reports · ")
                    + "lighter = estimated (~$) or backfilled · grey band = no data")
        }
    }

    private func spendScale(_ overview: DashboardOverview) -> (domain: [String], range: [Color]) {
        splitScale(overview, overview.spendProviders.map(\.id), overview.spendPerDay)
    }

    private func tokenScale(_ overview: DashboardOverview) -> (domain: [String], range: [Color]) {
        splitScale(overview, overview.providers.map(\.id), overview.tokensPerDay)
    }

    /// Provider colours, or with split on, a shade of the provider colour per account and grey
    /// for unattributed (V68). Only series drawn in range are kept, so the legend names them.
    private func splitScale(
        _ overview: DashboardOverview, _ providers: [ProviderID], _ amounts: [DashboardOverview.DayAmount]
    ) -> (domain: [String], range: [Color]) {
        guard !overview.splitAccounts.isEmpty else { return DashboardPalette.providerScale }
        let drawn = Set(amounts.map { overview.seriesName($0.provider, $0.part) })
        let entries = providers.flatMap { id -> [(String, Color)] in
            let color = DashboardPalette.color(id)
            guard let accounts = overview.splitAccounts[id] else { return [(id.displayHint, color)] }
            return accounts.enumerated().map { index, account in
                (overview.seriesName(id, .account(account.key)), DashboardPalette.shade(color, index, of: accounts.count))
            } + [(overview.seriesName(id, .unattributed), .gray)]
        }.filter { drawn.contains($0.0) }
        return (entries.map(\.0), entries.map(\.1))
    }

    private func eventLane(_ overview: DashboardOverview) -> some View {
        Chart(Array(overview.events.enumerated()), id: \.offset) { _, event in
            PointMark(
                x: .value("Time", event.time),
                y: .value("Provider", event.provider?.displayHint ?? "Total budget"))
                .symbol { Image(systemName: DashboardPalette.symbol(event.kind)).font(.caption) }
                .opacity(event.notified ? 1 : 0.4)
        }
        .chartXScale(domain: overview.range.chartDomain)
        .frame(height: CGFloat(40 + 22 * Set(overview.events.map(\.provider)).count))
        .overlay(alignment: .topTrailing) { DashboardNote("faded = not notified") }
    }

    private func quotaStrip(_ overview: DashboardOverview) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(overview.quotaRows) { row in
                HStack(spacing: 6) {
                    Button { model.section = .provider(row.provider) } label: {
                        Text([row.provider.displayHint, row.account?.label, row.window].compactMap { $0 }.joined(separator: " "))
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .buttonStyle(.link)
                    .frame(width: overview.splitAccounts.isEmpty ? 130 : 200, alignment: .leading)
                    HStack(spacing: 1) {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            quotaCell(cell)
                        }
                    }
                    .frame(height: 12)
                }
            }
            DashboardNote("peak band: under 80% · 80% · 95% · 100% · dashed = no data · faint = no value")
        }
    }

    @ViewBuilder
    private func quotaCell(_ cell: DashboardQuotaCell) -> some View {
        switch cell {
        case .band(let band):
            Rectangle().fill(DashboardPalette.band(band))
        case .noValue:
            Rectangle().fill(Color.secondary.opacity(0.15))
        case .gap:
            RoundedRectangle(cornerRadius: 1)
                .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2]))
        }
    }

    private func tokenChart(_ overview: DashboardOverview) -> some View {
        Chart {
            ForEach(overview.tokenGapKeys, id: \.self) { key in
                RectangleMark(x: .value("Day", DashboardRange.date(forKey: key), unit: .day))
                    .foregroundStyle(.gray.opacity(0.15))
            }
            ForEach(overview.tokensPerDay) { day in
                BarMark(
                    x: .value("Day", DashboardRange.date(forKey: day.key), unit: .day),
                    y: .value("Tokens", day.amount))
                    .foregroundStyle(by: .value("Provider", overview.seriesName(day.provider, day.part)))
                    .opacity(day.backfilled ? 0.55 : 1)
            }
        }
        .chartForegroundStyleScale(domain: tokenScale(overview).domain, range: tokenScale(overview).range)
        .chartXScale(domain: overview.range.chartDomain)
        .frame(height: 140)
    }

    // MARK: - Provider list

    /// One line per provider; the name selects its sidebar row (V52). Spend and value stay
    /// in separate columns (V26).
    private func providerList(_ overview: DashboardOverview) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Provider"); Text("Spend"); Text("Value"); Text("Tokens"); Text("Peak"); Text("Days")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(overview.providers, id: \.id) { provider in
                GridRow {
                    Button(provider.id.displayHint) { model.section = .provider(provider.id) }
                        .buttonStyle(.link)
                    Text(provider.hasSpend ? dashboardTotal(provider.spend, approximate: provider.spend.estimated) : "")
                    Text(provider.hasValue ? dashboardTotal(provider.value, approximate: true) : "")
                        .foregroundStyle(.secondary)
                    Text(provider.tokens.map { $0.formatted(.number.notation(.compactName)) } ?? "—")
                    Text(provider.peak.map { "\(Int(($0.fraction * 100).rounded()))% \($0.window)" } ?? "")
                    Text("\(provider.seenDays)/\(overview.range.keys.count)")
                }
                .font(.callout.monospacedDigit())
            }
        }
    }
}

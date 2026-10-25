import Charts
import SwiftUI

/// The Overview section (SPEC V53): tiles, month budget bars, spend per day stacked by
/// provider (metered only), an event lane, a quota band strip, and tokens per day. The range
/// and provider chips are shared state on the model. Markers follow V56.
struct DashboardOverviewView: View {
    @Bindable var model: DashboardModel
    let budgets: [DashboardBudget]
    let warningFraction: Double

    var body: some View {
        let overview = model.overview
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(overview.range)
                chips
                tiles(overview)
                if !budgets.isEmpty { budgetSection }
                section("Spend per day") { spendChart(overview) }
                if !overview.events.isEmpty {
                    section("Usage events") { eventLane(overview) }
                }
                if !overview.quotaRows.isEmpty {
                    section("Quota peak per day") { quotaStrip(overview) }
                }
                if !overview.tokensPerDay.isEmpty {
                    section("Tokens per day") { tokenChart(overview) }
                }
                section("By provider") { providerList(overview) }
            }
            .padding(20)
        }
    }

    // MARK: - Header, chips, tiles

    private func header(_ range: StatsRange) -> some View {
        HStack {
            Picker("Range", selection: $model.range) {
                ForEach(DashboardRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)
            Spacer()
            Text(rangeLabel(range))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rangeLabel(_ range: StatsRange) -> String {
        let first = DashboardRange.date(forKey: range.keys[0]).formatted(date: .abbreviated, time: .omitted)
        let last = DashboardRange.date(forKey: range.keys[range.keys.count - 1]).formatted(date: .abbreviated, time: .omitted)
        return "\(first) – \(last)" + (range.isTodayOpen ? " · today in progress" : "")
    }

    /// One chip per provider with a record in range; switching one off filters Overview and
    /// the Calendar heatmap (V53).
    private var chips: some View {
        let ids = DashboardOverview(days: model.days, range: model.range.statsRange(today: model.today), order: model.order)
            .providers.map(\.id)
        return HStack {
            ForEach(ids, id: \.self) { id in
                let on = !model.excluded.contains(id)
                let color = DashboardPalette.color(id)
                Button { model.toggle(id) } label: {
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(id.displayHint)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(on ? color.opacity(0.18) : .clear, in: Capsule())
                    .overlay(Capsule().stroke(color.opacity(on ? 0.6 : 0.2)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tiles(_ overview: DashboardOverview) -> some View {
        HStack(alignment: .top, spacing: 12) {
            spendTile(overview)
            if let value = overview.value {
                tile("Subscription value", total(value, approximate: true), note: "API-equivalent, not spend",
                     incomplete: value.incomplete, dimmed: true)
            }
            tile("Tokens", overview.tokens.map { $0.formatted(.number.notation(.compactName)) } ?? "—")
            tile("Usage events", "\(overview.events.count)", note: "\(overview.notNotifiedCount) not notified")
        }
    }

    private func spendTile(_ overview: DashboardOverview) -> some View {
        if overview.spendProviders.isEmpty {
            return tile("Spend", dashboardUSD(0), note: "no metered accounts")
        }
        let spend = overview.spend
        return tile("Spend", total(spend, approximate: spend.estimated), note: spend.estimated ? "includes estimated" : nil,
                    incomplete: spend.incomplete)
    }

    private func total(_ total: SpendTotal, approximate: Bool) -> String {
        total.amount.map { dashboardUSD($0, approximate: approximate) } ?? "—"
    }

    private func tile(
        _ title: String, _ value: String, note: String? = nil, incomplete: Bool = false, dimmed: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if incomplete { DashboardBadge(text: "incomplete") }
            }
            Text(value)
                .font(.title.bold().monospacedDigit())
                .foregroundStyle(dimmed ? .secondary : .primary)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(10)
        .frame(minWidth: 150, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var budgetSection: some View {
        let month = DashboardRange.date(forKey: model.today).formatted(.dateTime.month(.wide).year())
        return section("Budgets · \(month)") {
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

    private func xDomain(_ range: StatsRange) -> ClosedRange<Date> {
        let first = DashboardRange.date(forKey: range.keys[0])
        let last = DashboardRange.date(forKey: range.keys[range.keys.count - 1])
        return first...last.addingTimeInterval(86_400)
    }

    private var providerScale: (domain: [String], range: [Color]) {
        (ProviderID.allKnown.map(\.displayHint), ProviderID.allKnown.map(DashboardPalette.color))
    }

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
                        .foregroundStyle(by: .value("Provider", day.provider.displayHint))
                        .opacity(day.estimated || day.backfilled ? 0.55 : 1)
                }
            }
            .chartForegroundStyleScale(domain: providerScale.domain, range: providerScale.range)
            .chartXScale(domain: xDomain(overview.range))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(amount, format: .currency(code: "USD")) }
                    }
                }
            }
            .frame(height: 200)
            chartNote("lighter = estimated (~$) or backfilled · grey band = no data")
        }
    }

    private func eventLane(_ overview: DashboardOverview) -> some View {
        Chart(Array(overview.events.enumerated()), id: \.offset) { _, event in
            PointMark(
                x: .value("Time", event.time),
                y: .value("Provider", event.provider?.displayHint ?? "Total budget"))
                .symbol { Image(systemName: Self.symbol(event.kind)).font(.caption) }
                .opacity(event.notified ? 1 : 0.4)
        }
        .chartXScale(domain: xDomain(overview.range))
        .frame(height: CGFloat(40 + 22 * Set(overview.events.map(\.provider)).count))
        .overlay(alignment: .topTrailing) { chartNote("faded = not notified") }
    }

    private static func symbol(_ kind: UsageEventKind) -> String {
        switch kind {
        case .band80, .band95, .band100: return "exclamationmark.triangle.fill"
        case .pace: return "speedometer"
        case .reset: return "arrow.counterclockwise"
        case .authLost: return "lock.fill"
        case .authRecovered: return "lock.open.fill"
        case .budgetWarning, .budgetLimit: return "dollarsign.circle.fill"
        }
    }

    private func quotaStrip(_ overview: DashboardOverview) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(overview.quotaRows) { row in
                HStack(spacing: 6) {
                    Button { model.section = .provider(row.provider) } label: {
                        Text("\(row.provider.displayHint) \(row.window)").font(.caption)
                    }
                    .buttonStyle(.link)
                    .frame(width: 130, alignment: .leading)
                    HStack(spacing: 1) {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            quotaCell(cell)
                        }
                    }
                    .frame(height: 12)
                }
            }
            chartNote("peak band: under 80% · 80% · 95% · 100% · dashed = no data · faint = no value")
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
                    .foregroundStyle(by: .value("Provider", day.provider.displayHint))
                    .opacity(day.backfilled ? 0.55 : 1)
            }
        }
        .chartForegroundStyleScale(domain: providerScale.domain, range: providerScale.range)
        .chartXScale(domain: xDomain(overview.range))
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
                    Text(provider.hasSpend ? total(provider.spend, approximate: provider.spend.estimated) : "")
                    Text(provider.hasValue ? total(provider.value, approximate: true) : "")
                        .foregroundStyle(.secondary)
                    Text(provider.tokens.map { $0.formatted(.number.notation(.compactName)) } ?? "—")
                    Text(provider.peak.map { "\(Int(($0.fraction * 100).rounded()))% \($0.window)" } ?? "")
                    Text("\(provider.seenDays)/\(overview.range.keys.count)")
                }
                .font(.callout.monospacedDigit())
            }
        }
    }

    // MARK: - Layout helpers

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func chartNote(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
    }
}

import SwiftUI

/// The dashboard sidebar (SPEC V52): Overview, one row per provider with a 14-day mini chart
/// and its budget bar, local runtimes under "No cost data" with a days-seen strip, Calendar.
struct DashboardSidebarView: View {
    @Bindable var model: DashboardModel
    let budgets: [DashboardBudget]
    let warningFraction: Double

    var body: some View {
        let sidebar = model.sidebar
        List(selection: selection) {
            Label("Overview", systemImage: "square.grid.2x2")
                .tag(DashboardModel.Section.overview)
            if !sidebar.providers.isEmpty {
                Section("Providers") {
                    ForEach(sidebar.providers, id: \.id) { provider in
                        providerRow(provider)
                            .tag(DashboardModel.Section.provider(provider.id))
                    }
                }
            }
            if !sidebar.localRuntimes.isEmpty {
                Section("No cost data") {
                    ForEach(sidebar.localRuntimes, id: \.id) { provider in
                        providerRow(provider)
                            .tag(DashboardModel.Section.provider(provider.id))
                    }
                }
            }
            Label("Calendar", systemImage: "calendar")
                .tag(DashboardModel.Section.calendar)
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<DashboardModel.Section?> {
        Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })
    }

    private func providerRow(_ provider: ProviderStats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(DashboardPalette.color(provider.id)).frame(width: 8, height: 8)
                Text(provider.id.displayHint).bold()
                Spacer()
                Text("\(provider.seenDays)/\(DashboardSidebar.miniChartDays)d")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            DashboardMiniTrend(provider: provider)
            if let budget = budgets.first(where: { $0.scope == .provider(provider.id) }) {
                DashboardBudgetBar(label: "Budget", budget: budget, warningFraction: warningFraction)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A 14-day mini chart following the `aub stats` trend rule (V43, V64): spend for metered,
/// highest window peak for subscription and mixed, presence for local runtimes. A gap is a
/// dashed "no data" cell, a recorded day with no value a faint full-height cell, never low.
struct DashboardMiniTrend: View {
    let provider: ProviderStats

    var body: some View {
        let cells = provider.trend(bucketSize: 1)
        let top = provider.kind == .metered ? max(cells.compactMap(\.amount).max() ?? 0, .leastNonzeroMagnitude) : 1
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                cellView(cell, top: top)
            }
        }
        .frame(height: 22)
    }

    @ViewBuilder
    private func cellView(_ cell: ProviderStats.Cell, top: Double) -> some View {
        let color = DashboardPalette.color(provider.id)
        switch cell {
        case .value(let value):
            GeometryReader { geometry in
                Rectangle().fill(color)
                    .frame(height: max(2, geometry.size.height * min(value / top, 1)))
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        case .present:
            Rectangle().fill(color)
        case .noValue, .incomplete:
            Rectangle().fill(color.opacity(0.2))
        case .gap:
            RoundedRectangle(cornerRadius: 1)
                .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2]))
        }
    }
}

private extension ProviderStats.Cell {
    var amount: Double? {
        if case .value(let value) = self { return value }
        return nil
    }
}

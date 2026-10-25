import SwiftUI

/// Root of the dashboard window: the sidebar and the selected section (SPEC V52). History
/// is read when the window opens and only the open day is re-read after each poll (V20).
struct DashboardRootView: View {
    @Bindable var model: DashboardModel
    let store: AggregateStore

    var body: some View {
        NavigationSplitView {
            DashboardSidebarView(model: model, budgets: model.budgets(store.budgets), warningFraction: store.warningFraction)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
        .task { await model.load() }
        .onChange(of: store.lastTick) {
            Task { await model.reloadOpenDay() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let error = model.loadError {
            ContentUnavailableView("Usage history unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if !model.isLoaded {
            ProgressView()
        } else if model.days.isEmpty {
            ContentUnavailableView(
                "No history yet", systemImage: "chart.bar",
                description: Text("The app records from first launch; backfill runs in the background."))
        } else {
            switch model.section {
            case .overview:
                DashboardOverviewView(model: model, budgets: model.budgets(store.budgets), warningFraction: store.warningFraction)
            case .provider(let id):
                Text(id.displayHint)
                    .font(.title2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .calendar:
                Text("Calendar")
                    .font(.title2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Provider colours shared by every dashboard chart.
enum DashboardPalette {
    private static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown, .mint, .cyan]

    static func color(_ id: ProviderID) -> Color {
        let index = ProviderID.allKnown.firstIndex(of: id) ?? abs(id.rawValue.hashValue)
        return colors[index % colors.count]
    }

    static func band(_ band: ThresholdBand) -> Color {
        switch band {
        case .normal: return .green.opacity(0.55)
        case .warning: return .yellow
        case .critical: return .orange
        case .exceeded: return .red
        }
    }
}

/// `$1.23`, or `~$1.23` when any of it is estimated or it is value (V26, V56).
func dashboardUSD(_ amount: Decimal, approximate: Bool = false) -> String {
    (approximate ? "~" : "") + CLIFormat.usd(amount)
}

/// Grey "incomplete" badge for a partial range or month (V56).
struct DashboardBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// One month budget bar: month spend against the cap, coloured by band (V53).
struct DashboardBudgetBar: View {
    let label: String
    let budget: DashboardBudget
    let warningFraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.caption)
                if budget.spend.incomplete { DashboardBadge(text: "incomplete") }
                Spacer()
                Text("\(dashboardUSD(budget.spend.amount ?? 0, approximate: budget.spend.estimated)) / \(dashboardUSD(budget.cap.amount))")
                    .font(.caption.monospacedDigit())
            }
            ProgressView(value: min(budget.fraction, 1))
                .tint(budget.fraction >= 1 ? .red : budget.fraction >= warningFraction ? .orange : .accentColor)
        }
    }
}

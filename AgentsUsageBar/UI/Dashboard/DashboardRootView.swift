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
                DashboardProviderDetailView(model: model, id: id)
                    .id(id)
            case .calendar:
                DashboardCalendarView(model: model, budgets: model.budgets(store.budgets), warningFraction: store.warningFraction)
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

    /// Provider names and colours for `chartForegroundStyleScale`.
    static var providerScale: (domain: [String], range: [Color]) {
        (ProviderID.allKnown.map(\.displayHint), ProviderID.allKnown.map(color))
    }

    /// Diagonal hatching on a faint fill: the value series beside solid spend (V54).
    static func hatch(_ color: Color) -> ImagePaint {
        let stroke = NSColor(color)
        let image = NSImage(size: NSSize(width: 6, height: 6), flipped: false) { rect in
            stroke.withAlphaComponent(0.2).setFill()
            rect.fill()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX, y: rect.minY))
            line.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            line.lineWidth = 1.5
            stroke.setStroke()
            line.stroke()
            return true
        }
        return ImagePaint(image: Image(nsImage: image))
    }

    static func title(_ kind: UsageEventKind) -> String {
        switch kind {
        case .band80: return "80% band"
        case .band95: return "95% band"
        case .band100: return "100% band"
        case .pace: return "Pace warning"
        case .reset: return "Quota reset"
        case .authLost: return "Auth lost"
        case .authRecovered: return "Auth recovered"
        case .budgetWarning: return "Budget warning"
        case .budgetLimit: return "Budget 100%"
        }
    }

    static func symbol(_ kind: UsageEventKind) -> String {
        switch kind {
        case .band80, .band95, .band100: return "exclamationmark.triangle.fill"
        case .pace: return "speedometer"
        case .reset: return "arrow.counterclockwise"
        case .authLost: return "lock.fill"
        case .authRecovered: return "lock.open.fill"
        case .budgetWarning, .budgetLimit: return "dollarsign.circle.fill"
        }
    }
}

/// `$1.23`, or `~$1.23` when any of it is estimated or it is value (V26, V56).
func dashboardUSD(_ amount: Decimal, approximate: Bool = false) -> String {
    (approximate ? "~" : "") + CLIFormat.usd(amount)
}

/// A summed amount, or `—` when nothing is known (V7).
func dashboardTotal(_ total: SpendTotal, approximate: Bool) -> String {
    total.amount.map { dashboardUSD($0, approximate: approximate) } ?? "—"
}

/// The range picker shared by Overview and provider detail, and the days it covers (V52).
struct DashboardRangeHeader: View {
    @Bindable var model: DashboardModel

    var body: some View {
        let range = model.range.statsRange(today: model.today)
        HStack {
            Picker("Range", selection: $model.range) {
                ForEach(DashboardRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)
            Spacer()
            Text(label(range))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func label(_ range: StatsRange) -> String {
        let first = DashboardRange.date(forKey: range.keys[0]).formatted(date: .abbreviated, time: .omitted)
        let last = DashboardRange.date(forKey: range.keys[range.keys.count - 1]).formatted(date: .abbreviated, time: .omitted)
        return "\(first) – \(last)" + (range.isTodayOpen ? " · today in progress" : "")
    }
}

/// Provider chips: switching one off filters Overview and the Calendar heatmap, one shared
/// selection (V53).
struct DashboardChips: View {
    @Bindable var model: DashboardModel
    let ids: [ProviderID]

    var body: some View {
        HStack {
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
}

/// A titled block of the dashboard.
struct DashboardSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
        }
    }
}

/// A chart's small legend or caveat line.
struct DashboardNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
    }
}

/// A headline number. Value is dimmed (V26); a partial total gets the "incomplete" badge (V56).
struct DashboardTile: View {
    let title: String
    let value: String
    var note: String?
    var incomplete = false
    var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if incomplete { DashboardBadge(text: "incomplete") }
            }
            Text(value)
                .font(.title.bold().monospacedDigit())
                .foregroundStyle(dimmed ? .secondary : .primary)
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(minWidth: 150, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
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

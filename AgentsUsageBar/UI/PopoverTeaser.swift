import Foundation
import SwiftUI

/// The popover's 14-day strip (SPEC V59): 13 sealed days plus today, in progress. It plots
/// daily metered spend when any metered account appears in the 14 days, else the daily
/// highest quota peak. A gap is an empty slot, never zero. Budgets are not shown.
struct PopoverTeaser: Equatable, Sendable {
    enum Metric: Equatable, Sendable {
        case spend, peak

        var title: String {
            switch self {
            case .spend: return "Spend 14d"
            case .peak: return "Peak quota 14d"
            }
        }
    }

    struct Slot: Equatable, Sendable {
        let key: String
        /// Nil is an empty slot: no value that day.
        let value: Double?
        let isToday: Bool
    }

    let metric: Metric
    let slots: [Slot]

    /// Nil when no cost or quota provider has a record in the 14 days, so the popover hides it.
    init?(days: [DayFile], today: String) {
        let overview = DashboardOverview(days: days, range: DashboardRange.days14.statsRange(today: today))
        guard !overview.providers.isEmpty else { return nil }
        let keys = overview.range.keys
        if overview.spendProviders.isEmpty {
            metric = .peak
            let peaks = keys.indices.map { i in
                overview.providers.compactMap { $0.records[i]?.quota.values.map(\.peak).max() }.max()
            }
            slots = zip(keys, peaks).map { Slot(key: $0, value: $1, isToday: $0 == today) }
        } else {
            metric = .spend
            let spend = Dictionary(overview.spendPerDay.map { ($0.key, $0.amount) }, uniquingKeysWith: +)
            slots = keys.map { Slot(key: $0, value: spend[$0], isToday: $0 == today) }
        }
    }
}

/// Reads the teaser's 14 day files off the MainActor, on popover open only (V20).
struct PopoverTeaserSource: Sendable {
    let reader: HistoryReader
    let dayKeys: DayKeyOwner

    nonisolated func load() async -> PopoverTeaser? {
        let today = dayKeys.today()
        let keys = DashboardRange.days14.statsRange(today: today).keys
        guard let first = keys.first,
              let days = try? await reader.days(in: first...today)
        else { return nil }
        return PopoverTeaser(days: days, today: today)
    }
}

/// The teaser strip. Clicking it opens the dashboard (V51).
struct PopoverTeaserView: View {
    let teaser: PopoverTeaser

    var body: some View {
        Button {
            Task { try? await DashboardRoute().open() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(teaser.metric.title)
                    Spacer()
                    Text("today in progress")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(teaser.slots, id: \.key) { slot($0) }
                }
                .frame(height: 24)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the dashboard")
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var maxValue: Double {
        teaser.slots.compactMap(\.value).max() ?? 0
    }

    @ViewBuilder
    private func slot(_ slot: PopoverTeaser.Slot) -> some View {
        if let value = slot.value {
            let fraction = maxValue > 0 ? value / maxValue : 0
            Rectangle()
                .fill(color(value))
                .opacity(slot.isToday ? 0.5 : 1)
                .frame(maxWidth: .infinity)
                .frame(height: max(2, 24 * fraction))
        } else {
            // A gap is an empty slot, never a zero bar (V59).
            Rectangle()
                .strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
        }
    }

    private func color(_ value: Double) -> Color {
        switch teaser.metric {
        case .spend: return .accentColor
        case .peak: return DashboardPalette.band(DashboardQuotaCell.band(peak: value))
        }
    }
}

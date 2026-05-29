import SwiftUI

/// "Today total" header row at the top of the popover (UI-01).
///
/// Sums tokens + USD cost across all enabled providers from `AggregateStore.totals`.
/// In Phase 1 the sum is one provider (OpenRouter); structure is ready for Phase 2 fan-in.
public struct TotalsHeaderView: View {
    @Environment(AggregateStore.self) private var store

    public init() {}

    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(store.totals.tokens.formatted(.number)) tokens")
                    .font(.headline)
            }
            Spacer()
            Text(formattedUSD(store.totals.costUSD))
                .font(.headline)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func formattedUSD(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD"))
    }
}

// MARK: - Previews

#Preview("TotalsHeaderView — with data") {
    let store = AggregateStore(
        registry: [],
        clock: SystemClock(),
        cache: NoopCacheStore(),
        thresholds: ThresholdEngine(),
        notifications: NoopNotificationManager()
    )
    return TotalsHeaderView()
        .environment(store)
        .frame(width: 360)
}

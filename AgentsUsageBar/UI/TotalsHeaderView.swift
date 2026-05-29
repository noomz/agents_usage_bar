import SwiftUI

/// "Today total" header row at the top of the popover (UI-01).
///
/// Sums tokens + USD cost across all enabled providers from `AggregateStore.totals`.
/// Phase 1 sum was one provider (OpenRouter); Phase 3 extends this to four with
/// the additional D-07 rule: when any registered provider's
/// `capabilities.hasTokens == false` (Gemini in v1 — quota-only), the totals
/// row carries the explicit footnote "Total excludes quota-only providers".
/// The footnote is hidden when every registered provider reports tokens, so
/// the Phase 1 layout is preserved for installations without quota-only
/// providers.
public struct TotalsHeaderView: View {
    @Environment(AggregateStore.self) private var store

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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

            // Plan 03-07 / D-07 — footnote only when any registered provider
            // is quota-only (Gemini in v1). The padding is independent of the
            // header HStack so the totals layout stays untouched in the
            // no-footnote case.
            if store.hasAnyQuotaOnlyProvider {
                Text("Total excludes quota-only providers")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
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

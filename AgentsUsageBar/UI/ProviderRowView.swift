import SwiftUI

/// Per-provider row in the popover (UI-02).
///
/// Displays:
/// - Provider display name (subheadline)
/// - Status dot (ok/stale/error/unauthenticated/disabled)
/// - Today tokens ("—" for nil/cold-launch per D-03)
/// - Today USD cost ("—" for nil/cold-launch)
/// - Account balance (omitted when nil)
/// - Color-coded quota bar (QuotaBar) per UI-02 authoritative thresholds (B4)
/// - "Resets —" countdown (OpenRouter has no reset countdown — RESEARCH Open Question #4)
/// - "Updated Xs ago" relative timestamp label (ticks via TimelineView every 1s)
///
/// No `@StateObject`, `ObservableObject`, `@Published`, or Combine — pure value render from `ProviderState`.
public struct ProviderRowView: View {
    public let state: ProviderState
    /// Plan 02.07 — environment-injected store + clock for `isStale(_:now:)`.
    /// Available since Plan 01.08 wires both into the SwiftUI environment.
    @Environment(AggregateStore.self) private var store
    @Environment(\.clockService) private var clock

    public init(state: ProviderState) {
        self.state = state
    }

    public var body: some View {
        // Plan 02.07 (UI-08): wrap the row in a TimelineView so the staleness predicate
        // re-evaluates as time crosses the 2 × interval threshold. Body recomputation is
        // a single-row, integer-math cost — acceptable per RESEARCH §H.2.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let isStale = store.isStale(state.id, now: ctx.date)
            HStack(alignment: .top, spacing: 10) {
                // Status dot aligned to top of content
                StatusDot(status: state.status, isStale: isStale)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 4) {
                    // Provider name
                    Text(state.displayName)
                        .font(.subheadline.weight(.semibold))

                    // Token count · USD cost · balance
                    HStack(spacing: 4) {
                        Text(tokenText(state.snapshot))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(usdText(state.snapshot))
                            .font(.caption2)
                            .monospacedDigit()
                        if let bal = balanceText(state.snapshot), !bal.isEmpty {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(bal)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    // Quota bar
                    QuotaBar(quota: state.snapshot?.quota)
                        .frame(maxWidth: .infinity)

                    // Reset countdown + relative timestamp
                    HStack(spacing: 8) {
                        RelativeTimestampLabel(date: state.lastSuccess, isStale: isStale)
                        Spacer()
                        // OpenRouter has no per-day reset countdown (RESEARCH Open Question #4)
                        Text("Resets —")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Private helpers

    /// Today's token count as text. "—" when nil (cold-launch D-03 / OpenRouter no tokens D-03).
    private func tokenText(_ snapshot: UsageSnapshot?) -> String {
        guard let s = snapshot else { return "—" }
        guard let tokens = s.tokensToday else { return "—" }
        return "\(tokens.formatted(.number)) tokens"
    }

    /// Today's USD cost as text. "—" when nil (cold-launch D-03).
    private func usdText(_ snapshot: UsageSnapshot?) -> String {
        guard let s = snapshot else { return "—" }
        guard let cost = s.costTodayUSD else { return "—" }
        return cost.formatted(.currency(code: "USD"))
    }

    /// Account balance text, or nil when not available.
    private func balanceText(_ snapshot: UsageSnapshot?) -> String? {
        guard let s = snapshot, let bal = s.balanceUSD else { return nil }
        return "bal " + bal.formatted(.currency(code: "USD"))
    }
}

// MARK: - Previews

@MainActor
private func previewStore() -> AggregateStore {
    AggregateStore(
        registry: [],
        clock: SystemClock(),
        cache: NoopCacheStore(),
        thresholds: ThresholdEngine(),
        notifications: NoopNotificationManager()
    )
}

#Preview("ProviderRowView — ok with quota") {
    let snapshot = UsageSnapshot(
        providerID: ProviderID(rawValue: "openrouter"),
        asOf: .now,
        tokensToday: nil,
        costTodayUSD: Decimal(2.45),
        balanceUSD: Decimal(7.55),
        quota: Quota(used: 2.45, limit: 10.0, remaining: 7.55),
        raw: [:]
    )
    let state = ProviderState(
        id: ProviderID(rawValue: "openrouter"),
        displayName: "OpenRouter",
        snapshot: snapshot,
        status: .ok(lastSuccess: .now.addingTimeInterval(-30)),
        lastSuccess: .now.addingTimeInterval(-30)
    )
    return ProviderRowView(state: state)
        .environment(previewStore())
        .frame(width: 360)
}

#Preview("ProviderRowView — cold launch (no snapshot)") {
    let state = ProviderState(
        id: ProviderID(rawValue: "openrouter"),
        displayName: "OpenRouter",
        snapshot: nil,
        status: .unauthenticated,
        lastSuccess: nil
    )
    return ProviderRowView(state: state)
        .environment(previewStore())
        .frame(width: 360)
}

#Preview("ProviderRowView — error state") {
    let state = ProviderState(
        id: ProviderID(rawValue: "openrouter"),
        displayName: "OpenRouter",
        snapshot: nil,
        status: .error(ProviderError(kind: .auth, message: "HTTP 401")),
        lastSuccess: nil
    )
    return ProviderRowView(state: state)
        .environment(previewStore())
        .frame(width: 360)
}

import SwiftUI

/// Root view of the `MenuBarExtra(.window)` popover panel (UI-01, UI-07, SHELL-04).
///
/// Fixed at 360pt width (SHELL-04; Pitfall 1 mitigation: explicit fixed width prevents
/// `MenuBarExtra` from sizing to an indeterminate intrinsic size on first appearance).
///
/// Layout:
///   TotalsHeaderView   ← summed tokens + USD (UI-01)
///   Divider
///   ProviderRowView    ← one per provider, sorted by displayName
///   Divider
///   FooterView         ← Refresh now (Cmd-R) + Quit (Cmd-Q)
///
/// UI-07 guarantee: `AggregateStore.init` seeds `providers` from cache synchronously, so
/// this view renders cached values IMMEDIATELY on first open — no "Loading…" flash.
///
/// Uses `@Environment(AggregateStore.self)` (Observation framework, macOS 14+).
/// No `@StateObject`, `ObservableObject`, `@Published`, or `import Combine`.
public struct PopoverRootView: View {
    @Environment(AggregateStore.self) private var store

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TotalsHeaderView()
            Divider()
            ForEach(Array(sortedProviderStates().enumerated()), id: \.element.id) { idx, state in
                if idx > 0 { Divider() }
                ProviderRowView(state: state)
            }
            Divider()
            FooterView()
        }
        .frame(width: 360)
        .textSelection(.disabled)
        // POLL-03: trigger a refresh on popover open (coalesced if within 5s of last tick)
        .task {
            await store.refresh(now: Date.now)
        }
    }

    // MARK: - Helpers

    /// Provider states sorted alphabetically by displayName for stable row ordering.
    private func sortedProviderStates() -> [ProviderState] {
        store.providers.values.sorted { $0.displayName < $1.displayName }
    }
}

// MARK: - Preview

#Preview("PopoverRootView — with OpenRouter placeholder") {
    let store = AggregateStore(
        registry: [],
        clock: SystemClock(),
        cache: NoopCacheStore(),
        thresholds: ThresholdEngine(),
        notifications: NoopNotificationManager()
    )
    store.seedPlaceholder(
        providerID: ProviderID(rawValue: "openrouter"),
        displayName: "OpenRouter",
        status: .unauthenticated
    )
    return PopoverRootView()
        .environment(store)
}

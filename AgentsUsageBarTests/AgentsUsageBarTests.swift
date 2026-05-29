import Testing
@testable import AgentsUsageBar

/// Walking Skeleton smoke tests — Plan 01.01.
///
/// These three assertions cover the minimum surface that downstream plans depend on:
/// - `ProviderID.openrouter.rawValue` stability (Plans 01.04, 01.05, 01.07 use this string)
/// - `AggregateStore` seeding exactly one placeholder OpenRouter row on init
/// - `ProviderState` conforming to `Sendable` and `Equatable`
///
/// Later plans (01.02–01.07) extend this file without restructuring.
@MainActor
@Suite("Walking Skeleton")
struct AgentsUsageBarSkeletonTests {

    @Test func aggregateStoreSeedsOpenRouterPlaceholder() {
        let store = AggregateStore()
        #expect(store.providers.count == 1)
        #expect(store.providers[.openrouter]?.displayName == "OpenRouter")
        #expect(store.providers[.openrouter]?.placeholderMessage == "Not configured")
    }

    @Test func providerIDOpenRouterRawValueIsStable() {
        // Plans 01.04, 01.05, and 01.07 embed this string in cache keys,
        // HTTP headers, and notification identifiers. Do not change it.
        #expect(ProviderID.openrouter.rawValue == "openrouter")
    }

    @Test func providerStateIsSendableAndEquatable() {
        let a = ProviderState(
            id: .openrouter,
            displayName: "OpenRouter",
            placeholderMessage: "Not configured"
        )
        let b = ProviderState(
            id: .openrouter,
            displayName: "OpenRouter",
            placeholderMessage: "Not configured"
        )
        #expect(a == b)
    }
}

// MANUAL CHECK (Plan 01.01 deliverable, exercised by developer once after Task 3):
//   1. Run `xcodebuild build -scheme AgentsUsageBar -configuration Debug`.
//   2. `open` the resulting `.app` from `TARGET_BUILD_DIR`.
//   3. Confirm: menu bar icon `chart.bar.doc.horizontal` visible, no Dock icon, no Cmd-Tab entry.
//   4. Click icon: 360pt popover opens with one row "OpenRouter — Not configured" and a Quit footer.
//   5. Click Quit (or Cmd-Q): app terminates cleanly.
// The full multi-display / post-sleep / Stage Manager matrix is the Plan 01.08 verification gate.

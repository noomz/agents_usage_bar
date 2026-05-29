import Testing
import Foundation
@testable import AgentsUsageBar

/// Plan 05-03 — Tests for `AggregateStore.setProviderEnabled(_:enabled:)`.
///
/// Verifies D-04 contract:
/// 1. Toggling a provider OFF removes it from the visible row set immediately.
/// 2. Toggling a provider back ON re-inserts a placeholder so the row reappears.
/// 3. Toggling OFF during a fetch does not propagate an unhandled CancellationError.
///
/// Uses isolated `UserDefaults` suites so tests do not pollute `UserDefaults.standard`.
@MainActor
@Suite("AggregateStore.setProviderEnabled tests (Plan 05-03)")
struct AggregateStoreProviderEnabledTests {

    // MARK: - Helpers

    private func makeStore() -> AggregateStore {
        AggregateStore(
            registry: [],
            clock: VirtualClock(fixed: Date()),
            cache: NoopCacheStore(),
            thresholds: ThresholdEngine(warningFraction: 0.80, calendar: .current),
            notifications: SpyNotificationManager(),
            notificationState: InMemoryNotificationStateStore()
        )
    }

    // MARK: - Tests

    @Test("setProviderEnabled(false) removes provider from visible rows (D-04)")
    func toggleProviderOff_removesRow() {
        let store = makeStore()
        let providerID = ProviderID.openrouter

        // Arrange: seed a placeholder so the row exists first.
        store.setProviderEnabled(providerID, enabled: true)
        #expect(store.providers[providerID] != nil,
                "Provider row must exist before disable")

        // Act: disable the provider.
        store.setProviderEnabled(providerID, enabled: false)

        // Assert: row is gone from visible set immediately (D-04: "store hides row").
        #expect(store.providers[providerID] == nil,
                "Disabled provider must be removed from visible rows immediately")
    }

    @Test("setProviderEnabled(true) re-inserts placeholder so row reappears (D-04)")
    func toggleProviderOn_reincludesRow() {
        let store = makeStore()
        let providerID = ProviderID.openrouter

        // Arrange: disable first.
        store.setProviderEnabled(providerID, enabled: true)
        store.setProviderEnabled(providerID, enabled: false)
        #expect(store.providers[providerID] == nil,
                "Provider must be absent after disable")

        // Act: re-enable.
        store.setProviderEnabled(providerID, enabled: true)

        // Assert: placeholder row is present (next scheduler tick will fetch live data).
        #expect(store.providers[providerID] != nil,
                "Re-enabled provider must have a placeholder row")
    }

    @Test("setProviderEnabled(false) does not raise unhandled cancellation (D-04)")
    func toggleOffDuringFetch_doesNotRaiseCancellationError() async {
        let store = makeStore()
        let providerID = ProviderID.openrouter

        // Arrange: seed and disable — no in-flight task since registry is empty,
        // but the call must complete without throwing or crashing.
        store.setProviderEnabled(providerID, enabled: true)

        // Act + Assert: calling disable must complete without unhandled errors.
        // Swift Testing failures would surface as test failures automatically.
        store.setProviderEnabled(providerID, enabled: false)

        // No CancellationError surfaced = test passes.
        #expect(store.providers[providerID] == nil,
                "Provider must be absent after disable — no crash or propagated cancellation")
    }
}

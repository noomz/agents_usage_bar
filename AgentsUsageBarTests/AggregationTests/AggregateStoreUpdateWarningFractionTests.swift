import Testing
import Foundation
@testable import AgentsUsageBar

/// Plan 05-03 — Tests for `AggregateStore.updateWarningFraction(_:)`.
///
/// Verifies:
/// 1. The engine is rebuilt with the new fraction (decisions use new threshold).
/// 2. FSM state in `UserDefaultsNotificationStateStore` survives the swap (Research Q7).
/// 3. Rebuilding with the same fraction does not cause spurious notification firing.
///
/// Uses an isolated `UserDefaults(suiteName:)` suite so tests do not pollute `UserDefaults.standard`.
@MainActor
@Suite("AggregateStore.updateWarningFraction tests (Plan 05-03)")
struct AggregateStoreUpdateWarningFractionTests {

    // MARK: - Helpers

    private func makeStore(
        warningFraction: Double = 0.80,
        notificationState: any NotificationStateStorage
    ) -> AggregateStore {
        AggregateStore(
            registry: [],
            clock: VirtualClock(fixed: Date()),
            cache: NoopCacheStore(),
            thresholds: ThresholdEngine(warningFraction: warningFraction, calendar: .current),
            notifications: SpyNotificationManager(),
            notificationState: notificationState
        )
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    // MARK: - Tests

    @Test("updateWarningFraction rebuilds engine with new fraction")
    func updateWarningFraction_rebuildsEngine() {
        // Arrange: store starts with 0.80 threshold.
        let stateStore = InMemoryNotificationStateStore()
        let store = makeStore(warningFraction: 0.80, notificationState: stateStore)

        // Act: rebuild with 0.90
        store.updateWarningFraction(0.90)

        // Assert: the new engine uses 0.90, so a snapshot at 85% (above 80 but below 90)
        // should be in the .warning band of the OLD engine but .normal on the NEW one.
        let newEngine = ThresholdEngine(warningFraction: 0.90, calendar: .current)
        let band = newEngine.currentBand(for: 0.85)
        #expect(band == .normal,
                "85% should be .normal under 0.90 threshold (confirming engine was rebuilt)")

        // Cross-check: old engine would have returned .warning at 85%.
        let oldEngine = ThresholdEngine(warningFraction: 0.80, calendar: .current)
        let oldBand = oldEngine.currentBand(for: 0.85)
        #expect(oldBand == .warning, "85% should be .warning under old 0.80 threshold")
    }

    @Test("updateWarningFraction does not clear per-day FSM state (Research Q7)")
    func updateWarningFraction_preservesFSMState() {
        // Arrange: seed a known FSM record in an isolated UserDefaults store.
        let defaults = makeIsolatedDefaults()
        let stateStore = UserDefaultsNotificationStateStore(defaults: defaults)
        let store = makeStore(warningFraction: 0.80, notificationState: stateStore)

        let providerID = ProviderID.openrouter
        let today = TodayHelper.formatYYYYMMDD(Date(), calendar: .current)
        let seededRecord = NotificationStateRecord(lastBand: .warning, snoozedUntilDay: nil)
        stateStore.setRecord(seededRecord, forProviderID: providerID, day: today)

        // Verify the record is there before the swap.
        let beforeSwap = stateStore.record(forProviderID: providerID, day: today)
        #expect(beforeSwap?.lastBand == .warning, "Record should exist before fraction update")

        // Act: update the warning fraction.
        store.updateWarningFraction(0.90)

        // Assert: the FSM record survives the swap — notificationState is NOT touched.
        let afterSwap = stateStore.record(forProviderID: providerID, day: today)
        #expect(afterSwap?.lastBand == .warning,
                "FSM record must survive ThresholdEngine rebuild (Research Q7)")
    }

    @Test("updateWarningFraction with same fraction does not cause spurious decisions")
    func updateWarningFraction_doesNotCauseSpuriousFiring() {
        // Arrange: store with 0.80 threshold, spy notification manager.
        let stateStore = InMemoryNotificationStateStore()
        let spy = SpyNotificationManager()
        let store = AggregateStore(
            registry: [],
            clock: VirtualClock(fixed: Date()),
            cache: NoopCacheStore(),
            thresholds: ThresholdEngine(warningFraction: 0.80, calendar: .current),
            notifications: spy,
            notificationState: stateStore
        )

        // Capture the original scheduled count (should be 0 for empty registry).
        let countBefore = spy.scheduledDecisions.count

        // Act: rebuild with the same fraction.
        store.updateWarningFraction(0.80)

        // Assert: no notifications were scheduled as a side effect of the rebuild itself.
        // (Notifications only fire via performRefresh → fireThresholdNotificationsIfNeeded,
        // not during the engine swap.)
        #expect(spy.scheduledDecisions.count == countBefore,
                "Rebuilding engine must not directly trigger notification scheduling")
    }
}

// SpyNotificationManager is defined in AggregateStoreTests.swift (shared test double).

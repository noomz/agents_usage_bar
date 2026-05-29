import Testing
import Foundation
@testable import AgentsUsageBar

/// Plan 02.05 — covers `AggregateStore` snooze API + FSM-aware `fireThresholdNotificationsIfNeeded`.
@MainActor
@Suite("AggregateStoreSnoozeTests")
struct AggregateStoreSnoozeTests {

    /// Pinned to noon UTC so the date string matches across every reasonable test-host timezone
    /// (the production code uses `TodayHelper.formatYYYYMMDD(now)` with `Calendar.current`).
    static let now: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 13
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)!
    }()

    /// Derive `today` from `now` using the host calendar — matches the production code path
    /// inside `AggregateStore.snoozeToday(providerID:on:)` exactly.
    static var today: String { TodayHelper.formatYYYYMMDD(now) }
    static let pidA = ProviderID(rawValue: "openrouter")
    static let pidB = ProviderID(rawValue: "claude")

    /// Configurable-fetch provider for fraction-driven scenarios.
    final actor SnoozeFakeProvider: UsageProvider {
        nonisolated let id: ProviderID
        nonisolated let displayName: String
        nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
            hasQuota: true, hasCost: true, hasTokens: false, isLocal: false
        )

        private let fraction: Double

        init(id: ProviderID, displayName: String, fraction: Double) {
            self.id = id
            self.displayName = displayName
            self.fraction = fraction
        }

        func status() -> ProviderStatus { .ok(lastSuccess: Date()) }

        func fetch(now: Date) async throws -> UsageSnapshot {
            let limit = 100.0
            let used = fraction * limit
            return UsageSnapshot(
                providerID: id,
                asOf: now,
                tokensToday: nil,
                costTodayUSD: nil,
                balanceUSD: nil,
                quota: Quota(used: used, limit: limit, remaining: limit - used),
                raw: [:]
            )
        }
    }

    /// Captures the most recent `schedule(_:)` payload.
    final class CapturingNotificationManager: NotificationManager, @unchecked Sendable {
        private(set) var scheduledDecisions: [[NotificationDecision]] = []
        func schedule(_ decisions: [NotificationDecision]) async {
            scheduledDecisions.append(decisions)
        }
    }

    // MARK: - snoozeToday

    @Test("snoozeToday persists snoozedUntilDay for the provider")
    func snoozeToday_persists_snoozedUntilDay_in_state() {
        let state = InMemoryNotificationStateStore()
        let store = AggregateStore(
            registry: [],
            clock: VirtualClock(fixed: Self.now),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager(),
            notificationState: state
        )
        store.snoozeToday(providerID: Self.pidA, on: Self.now)
        #expect(state.record(forProviderID: Self.pidA, day: Self.today)?.snoozedUntilDay == Self.today)
    }

    @Test("snoozeAllToday persists snoozedUntilDay for every seeded provider")
    func snoozeAllToday_persists_for_all_seeded_providers() {
        let state = InMemoryNotificationStateStore()
        let store = AggregateStore(
            registry: [],
            clock: VirtualClock(fixed: Self.now),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager(),
            notificationState: state
        )
        store.seedPlaceholder(providerID: Self.pidA, displayName: "OpenRouter")
        store.seedPlaceholder(providerID: Self.pidB, displayName: "Claude")
        store.snoozeAllToday(on: Self.now)
        #expect(state.record(forProviderID: Self.pidA, day: Self.today)?.snoozedUntilDay == Self.today)
        #expect(state.record(forProviderID: Self.pidB, day: Self.today)?.snoozedUntilDay == Self.today)
    }

    // MARK: - fireThresholdNotificationsIfNeeded

    @Test("fireThresholdNotifications passes lastBands so warning→critical transitions fire :crit95")
    func fireThresholdNotificationsIfNeeded_passes_lastBands_to_engine() async throws {
        let state = InMemoryNotificationStateStore()
        // Pre-seed: provider A's lastBand = .warning. Now its fraction jumps to 0.96 (critical).
        state.setRecord(
            NotificationStateRecord(lastBand: .warning, snoozedUntilDay: nil),
            forProviderID: Self.pidA,
            day: Self.today
        )

        let provider = SnoozeFakeProvider(id: Self.pidA, displayName: "OpenRouter", fraction: 0.96)
        let spy = CapturingNotificationManager()
        let store = AggregateStore(
            registry: [provider],
            clock: VirtualClock(fixed: Self.now),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: spy,
            notificationState: state
        )

        await store.refresh(now: Self.now)

        try #require(spy.scheduledDecisions.count == 1)
        let payload = spy.scheduledDecisions[0]
        try #require(payload.count == 1)
        #expect(payload[0].band == .critical)
        #expect(payload[0].id.hasSuffix(":crit95"))

        // FSM state advances to .critical after the dispatch.
        #expect(state.record(forProviderID: Self.pidA, day: Self.today)?.lastBand == .critical)
    }

    @Test("fireThresholdNotifications respects pre-seeded snooze — zero decisions even at warning fraction")
    func fireThresholdNotificationsIfNeeded_respects_snooze() async throws {
        let state = InMemoryNotificationStateStore()
        // Pre-seed: provider A snoozed today; fraction will cross 0.85 (warning).
        state.setRecord(
            NotificationStateRecord(lastBand: .normal, snoozedUntilDay: Self.today),
            forProviderID: Self.pidA,
            day: Self.today
        )

        let provider = SnoozeFakeProvider(id: Self.pidA, displayName: "OpenRouter", fraction: 0.85)
        let spy = CapturingNotificationManager()
        let store = AggregateStore(
            registry: [provider],
            clock: VirtualClock(fixed: Self.now),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: spy,
            notificationState: state
        )

        await store.refresh(now: Self.now)

        try #require(spy.scheduledDecisions.count == 1)
        #expect(spy.scheduledDecisions[0].isEmpty)
    }
}

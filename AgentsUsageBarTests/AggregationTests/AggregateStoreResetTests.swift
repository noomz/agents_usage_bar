import Testing
import Foundation
@testable import AgentsUsageBar

@MainActor
@Suite("AggregateStoreResetTests")
struct AggregateStoreResetTests {

    static let now: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 9
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)!
    }()

    static var today: String { TodayHelper.formatYYYYMMDD(now) }

    final actor ResetFakeProvider: UsageProvider {
        nonisolated let id: ProviderID
        nonisolated let displayName: String
        nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
            hasQuota: true, hasCost: true, hasTokens: false, isLocal: false
        )
        private var windows: [QuotaWindow]
        private var quotaUsed: Double

        init(id: ProviderID, displayName: String, windows: [QuotaWindow], quotaUsed: Double = 0.4) {
            self.id = id
            self.displayName = displayName
            self.windows = windows
            self.quotaUsed = quotaUsed
        }

        func setWindows(_ windows: [QuotaWindow], quotaUsed: Double? = nil) {
            self.windows = windows
            if let quotaUsed { self.quotaUsed = quotaUsed }
        }

        func status() -> ProviderStatus { .ok(lastSuccess: Date()) }

        func fetch(now: Date) async throws -> UsageSnapshot {
            UsageSnapshot(
                providerID: id,
                asOf: now,
                tokensToday: nil,
                costTodayUSD: nil,
                balanceUSD: nil,
                quota: Quota(used: quotaUsed, limit: 1, remaining: 1 - quotaUsed),
                raw: [:],
                quotaWindows: windows
            )
        }
    }

    final class CapturingNotificationManager: NotificationManager, @unchecked Sendable {
        private(set) var scheduledDecisions: [[NotificationDecision]] = []
        func schedule(_ decisions: [NotificationDecision]) async {
            scheduledDecisions.append(decisions)
        }
    }

    func window(_ name: String, used: Double, remaining: TimeInterval, at now: Date) -> QuotaWindow {
        QuotaWindow(name: name, utilization: used, resetsAt: now.addingTimeInterval(remaining))
    }

    func resetBatches(_ spy: CapturingNotificationManager) -> [[NotificationDecision]] {
        spy.scheduledDecisions.filter { batch in
            batch.contains(where: { $0.id.contains(":reset:") })
        }
    }

    func makeStore(
        provider: ResetFakeProvider,
        spy: CapturingNotificationManager,
        state: InMemoryNotificationStateStore = InMemoryNotificationStateStore()
    ) -> AggregateStore {
        AggregateStore(
            registry: [provider],
            clock: VirtualClock(fixed: Self.now),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: spy,
            notificationState: state
        )
    }

    @Test("first poll does not fire; second poll after reset does")
    func secondPollAfterReset_fires() async throws {
        let provider = ResetFakeProvider(
            id: .claude,
            displayName: "Claude Code",
            windows: [window("5h", used: 0.90, remaining: 600, at: Self.now)],
            quotaUsed: 0.90
        )
        let spy = CapturingNotificationManager()
        let store = makeStore(provider: provider, spy: spy)

        await store.refresh(now: Self.now)
        #expect(resetBatches(spy).isEmpty)

        let later = Self.now.addingTimeInterval(700)
        await provider.setWindows(
            [window("5h", used: 0.05, remaining: 5 * 3600, at: later)],
            quotaUsed: 0.05
        )
        await store.refresh(now: later)

        let batches = resetBatches(spy)
        try #require(batches.count == 1)
        try #require(batches[0].count == 1)
        #expect(batches[0][0].id.contains(":reset:5h:"))
        #expect(batches[0][0].windowName == "5h")
        #expect(batches[0][0].body == "Usage is available again.")
    }

    @Test("reset decision is scheduled alone, not coalesced with the threshold batch")
    func reset_schedulesAlone() async throws {
        let provider = ResetFakeProvider(
            id: .claude,
            displayName: "Claude Code",
            windows: [window("5h", used: 0.90, remaining: 600, at: Self.now)],
            quotaUsed: 0.40
        )
        let spy = CapturingNotificationManager()
        let store = makeStore(provider: provider, spy: spy)

        await store.refresh(now: Self.now)
        let later = Self.now.addingTimeInterval(700)
        await provider.setWindows(
            [window("5h", used: 0.05, remaining: 5 * 3600, at: later)],
            quotaUsed: 0.05
        )
        await store.refresh(now: later)

        let batches = resetBatches(spy)
        try #require(batches.count == 1)
        #expect(batches[0].count == 1)
        #expect(batches[0][0].id.contains(":reset:"))
    }

    @Test("toggle off prevents reset notifications")
    func toggleOff_silent() async {
        let provider = ResetFakeProvider(
            id: .claude,
            displayName: "Claude Code",
            windows: [window("5h", used: 0.90, remaining: 600, at: Self.now)],
            quotaUsed: 0.90
        )
        let spy = CapturingNotificationManager()
        let store = makeStore(provider: provider, spy: spy)
        store.updateResetNotificationsEnabled(false)

        await store.refresh(now: Self.now)
        let later = Self.now.addingTimeInterval(700)
        await provider.setWindows(
            [window("5h", used: 0.05, remaining: 5 * 3600, at: later)],
            quotaUsed: 0.05
        )
        await store.refresh(now: later)
        #expect(resetBatches(spy).isEmpty)
    }

    @Test("snooze-today does not suppress reset notifications")
    func snoozeDoesNotSuppress() async throws {
        let state = InMemoryNotificationStateStore()
        let provider = ResetFakeProvider(
            id: .claude,
            displayName: "Claude Code",
            windows: [window("5h", used: 0.90, remaining: 600, at: Self.now)],
            quotaUsed: 0.40
        )
        let spy = CapturingNotificationManager()
        let store = makeStore(provider: provider, spy: spy, state: state)

        await store.refresh(now: Self.now)
        store.snoozeToday(providerID: .claude, on: Self.now)

        let later = Self.now.addingTimeInterval(700)
        await provider.setWindows(
            [window("5h", used: 0.05, remaining: 5 * 3600, at: later)],
            quotaUsed: 0.05
        )
        await store.refresh(now: later)

        try #require(resetBatches(spy).count == 1)
    }

    @Test("same reset does not fire twice")
    func oncePerReset() async throws {
        let state = InMemoryNotificationStateStore()
        let provider = ResetFakeProvider(
            id: .claude,
            displayName: "Claude Code",
            windows: [window("5h", used: 0.90, remaining: 600, at: Self.now)],
            quotaUsed: 0.40
        )
        let spy = CapturingNotificationManager()
        let store = makeStore(provider: provider, spy: spy, state: state)

        await store.refresh(now: Self.now)
        let later = Self.now.addingTimeInterval(700)
        await provider.setWindows(
            [window("5h", used: 0.05, remaining: 5 * 3600, at: later)],
            quotaUsed: 0.05
        )
        await store.refresh(now: later)
        await store.refresh(now: later.addingTimeInterval(60))

        #expect(resetBatches(spy).count == 1)
        let keys = state.record(forProviderID: .claude, day: Self.today)?.firedResetKeys ?? []
        #expect(!keys.isEmpty)
    }
}

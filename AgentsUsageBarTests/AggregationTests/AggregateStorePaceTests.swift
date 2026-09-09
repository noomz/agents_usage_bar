import Testing
import Foundation
@testable import AgentsUsageBar

@MainActor
@Suite("AggregateStorePaceTests")
struct AggregateStorePaceTests {

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

    final actor PaceFakeProvider: UsageProvider {
        nonisolated let id: ProviderID
        nonisolated let displayName: String
        nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
            hasQuota: true, hasCost: true, hasTokens: false, isLocal: false
        )
        private var windows: [QuotaWindow]

        init(id: ProviderID, displayName: String, windows: [QuotaWindow]) {
            self.id = id
            self.displayName = displayName
            self.windows = windows
        }

        func setWindows(_ windows: [QuotaWindow]) {
            self.windows = windows
        }

        func status() -> ProviderStatus { .ok(lastSuccess: Date()) }

        func fetch(now: Date) async throws -> UsageSnapshot {
            UsageSnapshot(
                providerID: id,
                asOf: now,
                tokensToday: nil,
                costTodayUSD: nil,
                balanceUSD: nil,
                quota: Quota(used: 0.4, limit: 1, remaining: 0.6),
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

    @Test("window-pace warning schedules separately from the threshold batch")
    func windowPace_schedulesAlone() async throws {
        let provider = PaceFakeProvider(
            id: .claude,
            displayName: "Claude Code",
            windows: [window("5h", used: 0.40, remaining: 4 * 3600, at: Self.now)]
        )
        let spy = CapturingNotificationManager()
        let store = AggregateStore(
            registry: [provider],
            clock: VirtualClock(fixed: Self.now),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: spy,
            notificationState: InMemoryNotificationStateStore()
        )

        await store.refresh(now: Self.now)

        // [0] = threshold batch (empty — 40% is below 80%); [1] = pace single.
        let paceBatches = spy.scheduledDecisions.filter { batch in
            batch.contains(where: { $0.windowName != nil })
        }
        try #require(paceBatches.count == 1)
        try #require(paceBatches[0].count == 1)
        #expect(paceBatches[0][0].id.hasSuffix(":pace:5h"))
        #expect(paceBatches[0][0].windowName == "5h")
    }

    @Test("recent-stream warning fires on the second poll")
    func recentStream_secondPoll() async throws {
        let provider = PaceFakeProvider(
            id: .gemini,
            displayName: "Gemini",
            windows: [window("gemini-2.5-pro", used: 0.20, remaining: 4 * 3600, at: Self.now)]
        )
        let spy = CapturingNotificationManager()
        let store = AggregateStore(
            registry: [provider],
            clock: VirtualClock(fixed: Self.now),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: spy,
            notificationState: InMemoryNotificationStateStore()
        )

        await store.refresh(now: Self.now)
        let afterFirst = spy.scheduledDecisions.filter { $0.contains(where: { $0.windowName != nil }) }
        #expect(afterFirst.isEmpty)

        let later = Self.now.addingTimeInterval(90)
        await provider.setWindows([window("gemini-2.5-pro", used: 0.28, remaining: 4 * 3600 - 90, at: later)])
        await store.refresh(now: later)

        let paceBatches = spy.scheduledDecisions.filter { $0.contains(where: { $0.windowName != nil }) }
        try #require(paceBatches.count == 1)
        #expect(paceBatches[0][0].providerID == .gemini)
    }

    @Test("toggle off prevents pace notifications")
    func toggleOff_silent() async {
        let provider = PaceFakeProvider(
            id: .claude,
            displayName: "Claude Code",
            windows: [window("5h", used: 0.40, remaining: 4 * 3600, at: Self.now)]
        )
        let spy = CapturingNotificationManager()
        let store = AggregateStore(
            registry: [provider],
            clock: VirtualClock(fixed: Self.now),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: spy,
            notificationState: InMemoryNotificationStateStore()
        )
        store.updatePaceWarningsEnabled(false)
        await store.refresh(now: Self.now)
        #expect(spy.scheduledDecisions.filter { $0.contains(where: { $0.windowName != nil }) }.isEmpty)
    }

    @Test("once per window per day")
    func oncePerWindowPerDay() async throws {
        let state = InMemoryNotificationStateStore()
        let provider = PaceFakeProvider(
            id: .claude,
            displayName: "Claude Code",
            windows: [window("5h", used: 0.40, remaining: 4 * 3600, at: Self.now)]
        )
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
        #expect(state.record(forProviderID: .claude, day: Self.today)?.firedPaceWindows == ["5h"])

        await store.refresh(now: Self.now.addingTimeInterval(60))
        let paceBatches = spy.scheduledDecisions.filter { $0.contains(where: { $0.windowName != nil }) }
        #expect(paceBatches.count == 1)
    }
}

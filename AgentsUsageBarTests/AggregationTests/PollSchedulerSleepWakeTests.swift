import Testing
import Foundation
import AppKit
@testable import AgentsUsageBar

// MARK: - Test doubles

/// Provider whose `fetch` can be configured to suspend forever (so we can verify
/// `stop()` cancels it via structured concurrency).
private final actor SleepWakeProvider: UsageProvider {
    nonisolated let id: ProviderID = ProviderID(rawValue: "sleep-wake-test")
    nonisolated let displayName: String = "SleepWakeProvider"
    nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: false, hasCost: true, hasTokens: false, isLocal: false
    )

    private var fetchCount = 0
    private var suspendForever = false

    func status() -> ProviderStatus { .unauthenticated }

    func setSuspendForever(_ v: Bool) { suspendForever = v }
    func count() -> Int { fetchCount }

    func fetch(now: Date) async throws -> UsageSnapshot {
        fetchCount += 1
        if suspendForever {
            try await Task.sleep(for: .seconds(60))
        }
        return UsageSnapshot(
            providerID: id, asOf: now,
            tokensToday: nil, costTodayUSD: nil, balanceUSD: nil,
            quota: nil, raw: [:]
        )
    }
}

private final class SleepWakeCacheStore: CacheStore, @unchecked Sendable {
    func loadAll() -> [ProviderID: ProviderState] { [:] }
    func save(_ providers: [ProviderID: ProviderState]) {}
    func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? { nil }
    func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {}
    private var transcriptOffsets: [String: TranscriptOffset] = [:]
    func transcriptOffset(forURL urlString: String) -> TranscriptOffset? { transcriptOffsets[urlString] }
    func setTranscriptOffset(_ offset: TranscriptOffset) { transcriptOffsets[offset.url] = offset }
    func allTranscriptOffsets() -> [String: TranscriptOffset] { transcriptOffsets }
}

@MainActor
private func makeStore(provider: SleepWakeProvider, clock: any Clock) -> AggregateStore {
    AggregateStore(
        registry: [provider],
        clock: clock,
        cache: SleepWakeCacheStore(),
        thresholds: ThresholdEngine(),
        notifications: NoopNotificationManager()
    )
}

@MainActor
private func makeStoreWithNotificationState(
    provider: SleepWakeProvider,
    clock: any Clock,
    notificationState: any NotificationStateStorage
) -> AggregateStore {
    AggregateStore(
        registry: [provider],
        clock: clock,
        cache: SleepWakeCacheStore(),
        thresholds: ThresholdEngine(),
        notifications: NoopNotificationManager(),
        notificationState: notificationState
    )
}

@Suite("PollSchedulerSleepWakeTests", .serialized)
@MainActor
struct PollSchedulerSleepWakeTests {

    // MARK: - Test 1: stop during in-flight cancels via structured concurrency

    @Test("scheduler_stop_during_inFlight_cancels_via_structured_concurrency")
    func scheduler_stop_during_inFlight_cancels_via_structured_concurrency() async throws {
        let provider = SleepWakeProvider()
        await provider.setSuspendForever(true)

        let clock = SystemClock()
        let store = makeStore(provider: provider, clock: clock)
        let scheduler = PollScheduler(store: store, clock: clock, interval: .m1)

        await scheduler.start()
        try await Task.sleep(for: .milliseconds(50))

        await scheduler.stop()

        // Within a small window, isRunning should be false.
        try await Task.sleep(for: .milliseconds(150))
        let running = await scheduler.isRunning()
        #expect(running == false, "scheduler.stop() must cancel the in-flight loop within 1s")
    }

    // MARK: - Test 2: start after stop resumes polling

    @Test("scheduler_start_after_stop_resumes_polling")
    func scheduler_start_after_stop_resumes_polling() async throws {
        let provider = SleepWakeProvider()
        // VirtualClock that advances 10s between calls — bypasses POLL-03's 5s coalescing
        // debounce so the second `start()` actually triggers a refresh (mirrors the
        // pattern in PollSchedulerTests/updateIntervalReplacesLoop).
        nonisolated(unsafe) var callIndex = 0
        let t0 = Date()
        let clock = VirtualClock {
            callIndex += 1
            return t0.addingTimeInterval(Double(callIndex) * 10)
        }
        let store = makeStore(provider: provider, clock: clock)
        let scheduler = PollScheduler(store: store, clock: clock, interval: .m1)

        await scheduler.start()
        try await Task.sleep(for: .milliseconds(150))
        let countAfterStart = await provider.count()
        #expect(countAfterStart >= 1)

        await scheduler.stop()
        try await Task.sleep(for: .milliseconds(50))

        await scheduler.start()
        try await Task.sleep(for: .milliseconds(200))

        let countAfterResume = await provider.count()
        #expect(countAfterResume >= countAfterStart + 1, "scheduler.start() after stop() must resume polling")

        await scheduler.stop()
    }

    // MARK: - Test 3: Pitfall 4 — wake-then-immediate-threshold race
    //
    // Seed the notification FSM with a pre-existing warning record for provider X. When
    // PowerObserver.handleWake fires (or scheduler.start() ticks immediately on wake), the
    // FSM state record must still be readable (not cleared during wake). The expected
    // contract: UserDefaults keys are date-scoped → on the SAME day, prior FSM state
    // survives across sleep/wake.

    @Test("wake_then_immediate_refresh_does_not_lose_FSM_state")
    func wake_then_immediate_refresh_does_not_lose_FSM_state() async throws {
        let notificationState = InMemoryNotificationStateStore()
        let provider = SleepWakeProvider()
        let clock = SystemClock()
        let now = clock.now()
        let today = TodayHelper.formatYYYYMMDD(now)

        let providerX = ProviderID(rawValue: "powX")
        let seededRecord = NotificationStateRecord(lastBand: .warning, snoozedUntilDay: nil)
        notificationState.setRecord(seededRecord, forProviderID: providerX, day: today)

        let store = makeStoreWithNotificationState(
            provider: provider,
            clock: clock,
            notificationState: notificationState
        )
        let scheduler = PollScheduler(store: store, clock: clock, interval: .manual)

        // Construct PowerObserver and trigger handleWake — simulates the wake path.
        let observer = PowerObserver(
            store: store,
            scheduler: scheduler,
            clock: clock,
            notificationCenter: NotificationCenter()
        )
        _ = observer
        await observer.handleWake()

        // FSM state record must still be readable post-wake.
        let preserved = notificationState.record(forProviderID: providerX, day: today)
        #expect(preserved != nil, "wake must not clear FSM state — Pitfall 4 mitigation")
        #expect(preserved?.lastBand == .warning)

        await scheduler.stop()
    }
}

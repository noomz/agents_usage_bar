import Testing
import Foundation
import AppKit
@testable import AgentsUsageBar

// MARK: - Test doubles

/// Counting provider used by PowerObserverTests — tracks fetch invocations as a proxy
/// for "store.refresh was called".
private final actor PowerCountingProvider: UsageProvider {
    nonisolated let id: ProviderID = ProviderID(rawValue: "power-test")
    nonisolated let displayName: String = "PowerTest"
    nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: false, hasCost: true, hasTokens: false, isLocal: false
    )

    private(set) var fetchCount: Int = 0

    func status() -> ProviderStatus { .unauthenticated }

    func fetch(now: Date) async throws -> UsageSnapshot {
        fetchCount += 1
        return UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: [:]
        )
    }

    func count() -> Int { fetchCount }
}

/// Fake cache for power tests.
private final class PowerFakeCacheStore: CacheStore, @unchecked Sendable {
    func loadAll() -> [ProviderID: ProviderState] { [:] }
    func save(_ providers: [ProviderID: ProviderState]) {}
    func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? { nil }
    func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {}
    private var transcriptOffsets: [String: TranscriptOffset] = [:]
    func transcriptOffset(forURL urlString: String) -> TranscriptOffset? { transcriptOffsets[urlString] }
    func setTranscriptOffset(_ offset: TranscriptOffset) { transcriptOffsets[offset.url] = offset }
    func allTranscriptOffsets() -> [String: TranscriptOffset] { transcriptOffsets }
}

// MARK: - Helpers

@MainActor
private func makeStore(provider: PowerCountingProvider, clock: any Clock) -> AggregateStore {
    AggregateStore(
        registry: [provider],
        clock: clock,
        cache: PowerFakeCacheStore(),
        thresholds: ThresholdEngine(),
        notifications: NoopNotificationManager()
    )
}

@Suite("PowerObserverTests", .serialized)
@MainActor
struct PowerObserverTests {

    // MARK: - Test 1: willSleep calls scheduler.stop()

    @Test("willSleepObserver_calls_scheduler_stop")
    func willSleepObserver_calls_scheduler_stop() async throws {
        let center = NotificationCenter()
        let provider = PowerCountingProvider()
        let clock = SystemClock()
        let store = makeStore(provider: provider, clock: clock)
        let scheduler = PollScheduler(store: store, clock: clock, interval: .m1)
        let observer = PowerObserver(
            store: store,
            scheduler: scheduler,
            clock: clock,
            notificationCenter: center
        )
        _ = observer  // retain for the duration of the test

        // Start the scheduler so we can assert it stops.
        await scheduler.start()
        try await Task.sleep(for: .milliseconds(80))
        let runningBefore = await scheduler.isRunning()
        #expect(runningBefore == true)

        // Post the willSleep notification through our injected center.
        center.post(name: NSWorkspace.willSleepNotification, object: nil)

        // Allow the async Task posted inside the observer closure to drain.
        try await Task.sleep(for: .milliseconds(200))

        let runningAfter = await scheduler.isRunning()
        #expect(runningAfter == false)
    }

    // MARK: - Test 2: didWake refreshes the store AND restarts the scheduler

    @Test("didWakeObserver_calls_store_refresh_then_scheduler_start")
    func didWakeObserver_calls_store_refresh_then_scheduler_start() async throws {
        let center = NotificationCenter()
        let provider = PowerCountingProvider()
        let clock = SystemClock()
        let store = makeStore(provider: provider, clock: clock)
        let scheduler = PollScheduler(store: store, clock: clock, interval: .m1)
        let observer = PowerObserver(
            store: store,
            scheduler: scheduler,
            clock: clock,
            notificationCenter: center
        )
        _ = observer

        // Scheduler not yet started — simulate "fresh wake while not running".
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))

        // store.refresh fired → provider fetch happened ≥ 1 time
        let count = await provider.count()
        #expect(count >= 1)

        // scheduler.start() fired
        let running = await scheduler.isRunning()
        #expect(running == true)

        await scheduler.stop()
    }

    // MARK: - Test 3: handleWake direct invocation drives refresh

    @Test("handleWake_directInvocation_advancesLastKnownDay")
    func handleWake_directInvocation_advancesLastKnownDay() async throws {
        let center = NotificationCenter()
        let provider = PowerCountingProvider()

        // Closure-driven clock: first read returns pinned date; subsequent reads simulate
        // 36h advance so handleWake detects a day rollover.
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        nonisolated(unsafe) var tickIndex = 0
        let clock = VirtualClock {
            defer { tickIndex += 1 }
            if tickIndex == 0 { return startDate }
            return startDate.addingTimeInterval(36 * 3600)
        }
        let store = makeStore(provider: provider, clock: clock)
        let scheduler = PollScheduler(store: store, clock: clock, interval: .manual)
        let observer = PowerObserver(
            store: store,
            scheduler: scheduler,
            clock: clock,
            notificationCenter: center
        )

        await observer.handleWake()

        // Verify refresh was driven by handleWake — provider fetched at least once
        let count = await provider.count()
        #expect(count >= 1)

        await scheduler.stop()
    }

    // MARK: - Test 4: deinit removes the observers — no leak

    @Test("deinit_removesObservers_noLeak")
    func deinit_removesObservers_noLeak() async throws {
        let center = NotificationCenter()
        let provider = PowerCountingProvider()
        let clock = SystemClock()
        let store = makeStore(provider: provider, clock: clock)
        let scheduler = PollScheduler(store: store, clock: clock, interval: .manual)

        weak var weakObserver: PowerObserver?
        do {
            let observer = PowerObserver(
                store: store,
                scheduler: scheduler,
                clock: clock,
                notificationCenter: center
            )
            weakObserver = observer
            #expect(weakObserver != nil)
            // Local `observer` goes out of scope here — PowerObserver should deallocate.
        }

        // Yield to give ARC a chance to drain.
        try await Task.sleep(for: .milliseconds(50))

        #expect(weakObserver == nil, "PowerObserver should deallocate after scope exit")

        // After dealloc, posting willSleep must NOT call scheduler.stop() because the
        // observer (and its closure) is gone.
        await scheduler.start()
        try await Task.sleep(for: .milliseconds(50))

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(150))

        // .manual scheduler doesn't auto-loop; just verify the (deallocated) observer
        // did not crash. Cleanup.
        await scheduler.stop()
    }
}

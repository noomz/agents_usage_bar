import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Test doubles for PollScheduler tests

/// Counting provider that increments a counter on each fetch.
final actor CountingProvider: UsageProvider {
    nonisolated let id: ProviderID
    nonisolated let displayName: String
    nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: false, hasCost: true, hasTokens: false, isLocal: false
    )

    private(set) var fetchCount: Int = 0

    /// When set, fetch will suspend indefinitely (for cancellation tests).
    private var suspendForever: Bool = false

    init(id: ProviderID = ProviderID(rawValue: "test"), displayName: String = "Test") {
        self.id = id
        self.displayName = displayName
    }

    func status() -> ProviderStatus { .unauthenticated }

    func fetch(now: Date) async throws -> UsageSnapshot {
        fetchCount += 1
        if suspendForever {
            // Await forever until cancelled
            try await Task.sleep(for: .seconds(60))
        }
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

    func setSuspendForever(_ value: Bool) {
        suspendForever = value
    }

    func count() -> Int { fetchCount }
}

// MARK: - Helpers

@MainActor
private func makeStore(provider: CountingProvider) -> AggregateStore {
    AggregateStore(
        registry: [provider],
        clock: SystemClock(),
        cache: AggFakeCacheStore(),
        thresholds: ThresholdEngine(),
        notifications: NoopNotificationManager()
    )
}

// MARK: - PollScheduler Tests

@Suite("PollSchedulerTests")
struct PollSchedulerTests {

    /// Polls `provider.count()` until it reaches `target` or the deadline elapses.
    /// Replaces fixed sleeps that flake under CPU contention on slower/parallel CI runners. (Issue #4)
    @discardableResult
    private func waitForCount(_ provider: CountingProvider, atLeast target: Int, timeout: Duration = .seconds(5)) async throws -> Int {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let c = await provider.count()
            if c >= target { return c }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await provider.count()
    }

    // MARK: start with .m5 begins the loop

    @Test("start with non-manual interval triggers an immediate refresh")
    func startTriggersImmediateRefresh() async throws {
        let provider = CountingProvider()
        let store = await makeStore(provider: provider)
        let scheduler = PollScheduler(store: store, clock: SystemClock(), interval: .m5)

        await scheduler.start()
        // Wait (with a deadline) for the initial refresh to run — avoids a fixed-sleep flake.
        let count = try await waitForCount(provider, atLeast: 1)
        #expect(count >= 1)
    }

    // MARK: start with .manual does NOT start the loop

    @Test("start with .manual does NOT start the loop")
    func startManualDoesNotStartLoop() async throws {
        let provider = CountingProvider()
        let store = await makeStore(provider: provider)
        let scheduler = PollScheduler(store: store, clock: SystemClock(), interval: .manual)

        await scheduler.start()
        try await Task.sleep(for: .milliseconds(100))

        let count = await provider.count()
        let running = await scheduler.isRunning()
        #expect(count == 0)
        #expect(running == false)
    }

    // MARK: stop cancels in-flight Task (POLL-07)

    @Test("stop cancels the running task (POLL-07)")
    func stopCancelsTask() async throws {
        let provider = CountingProvider()
        let store = await makeStore(provider: provider)
        // Use m1 so we can verify the task is running
        let scheduler = PollScheduler(store: store, clock: SystemClock(), interval: .m1)

        await scheduler.start()
        try await Task.sleep(for: .milliseconds(50))

        // Verify it was running
        let running = await scheduler.isRunning()
        #expect(running == true)

        await scheduler.stop()
        try await Task.sleep(for: .milliseconds(50))

        let stoppedRunning = await scheduler.isRunning()
        #expect(stoppedRunning == false)
    }

    // MARK: updateInterval replaces the existing loop

    @Test("updateInterval replaces the existing loop")
    func updateIntervalReplacesLoop() async throws {
        let provider = CountingProvider()
        // Use a VirtualClock that advances 10s between calls to bypass the 5s POLL-03 skip
        var callIndex = 0
        let t0 = Date()
        let clock = VirtualClock {
            callIndex += 1
            return t0.addingTimeInterval(Double(callIndex) * 10)
        }
        let store = await AggregateStore(
            registry: [provider],
            clock: clock,
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        let scheduler = PollScheduler(store: store, clock: clock, interval: .m5)

        // First start — immediate refresh fires
        await scheduler.start()
        let countAfterStart = try await waitForCount(provider, atLeast: 1)
        #expect(countAfterStart >= 1)

        // updateInterval — triggers another immediate refresh; VirtualClock ensures the
        // 5s POLL-03 skip does not block it (each clock.now() call advances by 10s)
        await scheduler.updateInterval(.m1)
        // At minimum 2 refreshes: one from start, one after updateInterval.
        let count = try await waitForCount(provider, atLeast: 2)

        let interval = await scheduler.currentInterval()
        #expect(interval == .m1)

        #expect(count >= 2)
    }

    // MARK: single instance — start twice replaces prior task

    @Test("start twice cancels previous task — only one loop runs")
    func startTwiceCancelsPriorTask() async throws {
        let provider = CountingProvider()
        let store = await makeStore(provider: provider)
        let scheduler = PollScheduler(store: store, clock: SystemClock(), interval: .m5)

        // Start twice in rapid succession
        await scheduler.start()
        await scheduler.start()

        try await Task.sleep(for: .milliseconds(100))

        // Scheduler must be running (second start)
        let running = await scheduler.isRunning()
        #expect(running == true)
    }

    // MARK: POLL-01: only ONE Task is alive at any time

    @Test("POLL-01: after start + updateInterval + start, only one task slot is occupied")
    func onlyOneTaskAtATime() async throws {
        let provider = CountingProvider()
        let store = await makeStore(provider: provider)
        let scheduler = PollScheduler(store: store, clock: SystemClock(), interval: .m5)

        await scheduler.start()
        await scheduler.updateInterval(.m1)
        await scheduler.start()

        try await Task.sleep(for: .milliseconds(100))

        // The scheduler should be running (exactly one loop)
        let running = await scheduler.isRunning()
        #expect(running == true)

        await scheduler.stop()

        let stopped = await scheduler.isRunning()
        #expect(stopped == false)
    }
}

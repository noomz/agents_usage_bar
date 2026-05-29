import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Test Doubles

/// Fake provider that counts fetch calls and returns a configurable snapshot or error.
final actor FakeProvider: UsageProvider {
    nonisolated let id: ProviderID
    nonisolated let displayName: String
    nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: false, hasCost: true, hasTokens: false, isLocal: false
    )

    private var fetchResult: Result<UsageSnapshot, Error>
    private(set) var fetchCallCount: Int = 0

    init(id: ProviderID, displayName: String, result: Result<UsageSnapshot, Error>) {
        self.id = id
        self.displayName = displayName
        self.fetchResult = result
    }

    func status() -> ProviderStatus { .unauthenticated }

    func fetch(now: Date) async throws -> UsageSnapshot {
        fetchCallCount += 1
        switch fetchResult {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }

    func setResult(_ result: Result<UsageSnapshot, Error>) {
        self.fetchResult = result
    }

    func callCount() -> Int { fetchCallCount }
}

/// Fake cache that records calls.
final class AggFakeCacheStore: CacheStore, @unchecked Sendable {
    var storedProviders: [ProviderID: ProviderState]
    private(set) var savedCallCount: Int = 0
    private(set) var lastSaved: [ProviderID: ProviderState]?

    init(providers: [ProviderID: ProviderState] = [:]) {
        self.storedProviders = providers
    }

    func loadAll() -> [ProviderID: ProviderState] { storedProviders }

    func save(_ providers: [ProviderID: ProviderState]) {
        savedCallCount += 1
        lastSaved = providers
    }

    func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? { nil }

    func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {}
}

/// Spy notification manager that records schedule calls.
final class SpyNotificationManager: NotificationManager, @unchecked Sendable {
    private(set) var scheduledDecisions: [[NotificationDecision]] = []

    func schedule(_ decisions: [NotificationDecision]) async {
        scheduledDecisions.append(decisions)
    }
}

/// Spy threshold engine that returns configurable decisions.
struct SpyThresholdEngine: Sendable {
    let decisionsToReturn: [NotificationDecision]

    init(decisions: [NotificationDecision] = []) {
        self.decisionsToReturn = decisions
    }

    func decisions(
        for snapshots: [UsageSnapshot],
        now: Date,
        snoozedUntil: [ProviderID: Date]
    ) -> [NotificationDecision] {
        decisionsToReturn
    }
}

// MARK: - Helpers

private func makeSnapshot(
    providerID: ProviderID,
    now: Date,
    tokens: Int? = nil,
    costUSD: Decimal? = 1.00
) -> UsageSnapshot {
    UsageSnapshot(
        providerID: providerID,
        asOf: now,
        tokensToday: tokens,
        costTodayUSD: costUSD,
        balanceUSD: nil,
        quota: nil,
        raw: [:]
    )
}

// MARK: - AggregateStore Tests

@MainActor
@Suite("AggregateStoreTests")
struct AggregateStoreTests {

    // MARK: init seeds from cache synchronously (UI-07)

    @Test("init seeds providers synchronously from cache (UI-07)")
    func initSeedsFromCache() {
        let idA = ProviderID(rawValue: "providerA")
        let idB = ProviderID(rawValue: "providerB")
        let now = Date()
        let stateA = ProviderState.placeholder(providerID: idA, displayName: "Provider A")
        let stateB = ProviderState.placeholder(providerID: idB, displayName: "Provider B")
        let cache = AggFakeCacheStore(providers: [idA: stateA, idB: stateB])

        let store = AggregateStore(
            registry: [],
            clock: VirtualClock(fixed: now),
            cache: cache,
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )

        #expect(store.providers.count == 2)
        #expect(store.providers[idA] != nil)
        #expect(store.providers[idB] != nil)
    }

    // MARK: rollupTotals

    @Test("rollupTotals sums costTodayUSD and tokensToday, nil tokens treated as 0")
    func rollupTotalsNilTokens() {
        let idA = ProviderID(rawValue: "provA")
        let idB = ProviderID(rawValue: "provB")
        let now = Date()
        let snapA = makeSnapshot(providerID: idA, now: now, tokens: nil, costUSD: Decimal(string: "1.50"))
        let snapB = makeSnapshot(providerID: idB, now: now, tokens: 200, costUSD: Decimal(string: "0.30"))
        let stateA = ProviderState.initial(snapshot: snapA, at: now)
        let stateB = ProviderState.initial(snapshot: snapB, at: now)
        let cache = AggFakeCacheStore(providers: [idA: stateA, idB: stateB])

        let store = AggregateStore(
            registry: [],
            clock: VirtualClock(fixed: now),
            cache: cache,
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )

        #expect(store.totals.tokens == 200)
        let expectedCost = Decimal(string: "1.80")!
        #expect(store.totals.costUSD == expectedCost)
    }

    // MARK: refresh fan-out

    @Test("refresh fans out to providers and updates state")
    func refreshFansOut() async {
        let id = ProviderID(rawValue: "openrouter")
        let now = Date()
        let snap = makeSnapshot(providerID: id, now: now)
        let provider = FakeProvider(id: id, displayName: "OpenRouter", result: .success(snap))
        let cache = AggFakeCacheStore()

        let store = AggregateStore(
            registry: [provider],
            clock: VirtualClock(fixed: now),
            cache: cache,
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )

        await store.refresh(now: now)

        let count = await provider.callCount()
        #expect(count == 1)
        #expect(store.providers[id] != nil)
        if case .ok = store.providers[id]?.status { } else {
            Issue.record("Expected .ok status")
        }
        #expect(store.lastTick == now)
    }

    // MARK: coalescing

    @Test("refresh coalesces concurrent callers — provider fetched exactly once")
    func refreshCoalescesConcurrentCallers() async {
        let id = ProviderID(rawValue: "openrouter")
        let now = Date()
        let snap = makeSnapshot(providerID: id, now: now)
        let provider = FakeProvider(id: id, displayName: "OpenRouter", result: .success(snap))
        let cache = AggFakeCacheStore()

        let store = AggregateStore(
            registry: [provider],
            clock: VirtualClock(fixed: now),
            cache: cache,
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )

        // First refresh to set lastTick
        await store.refresh(now: now)
        let countAfterFirst = await provider.callCount()
        #expect(countAfterFirst == 1)

        // Reset for the coalescing test — use a time far enough in the future
        let t1 = now.addingTimeInterval(10)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.refresh(now: t1) }
            group.addTask { await store.refresh(now: t1) }
        }

        let finalCount = await provider.callCount()
        // Should be 2 total (1 from first refresh + 1 from the coalesced pair)
        #expect(finalCount == 2)
    }

    // MARK: 5s skip

    @Test("refresh skips when lastTick < 5s ago (POLL-03)")
    func refreshSkipsWhenWithin5Seconds() async {
        let id = ProviderID(rawValue: "openrouter")
        let t0 = Date()
        let snap = makeSnapshot(providerID: id, now: t0)
        let provider = FakeProvider(id: id, displayName: "OpenRouter", result: .success(snap))
        let cache = AggFakeCacheStore()

        let store = AggregateStore(
            registry: [provider],
            clock: VirtualClock(fixed: t0),
            cache: cache,
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )

        await store.refresh(now: t0)
        let after1 = await provider.callCount()
        #expect(after1 == 1)

        // Second call 4 seconds later — should be skipped
        let t1 = t0.addingTimeInterval(4)
        await store.refresh(now: t1)
        let after2 = await provider.callCount()
        #expect(after2 == 1) // still 1 — skipped
    }

    @Test("refresh runs when lastTick >= 5s ago (POLL-03)")
    func refreshRunsWhen5SecondsElapsed() async {
        let id = ProviderID(rawValue: "openrouter")
        let t0 = Date()
        let snap = makeSnapshot(providerID: id, now: t0)
        let provider = FakeProvider(id: id, displayName: "OpenRouter", result: .success(snap))
        let cache = AggFakeCacheStore()

        let store = AggregateStore(
            registry: [provider],
            clock: VirtualClock(fixed: t0),
            cache: cache,
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )

        await store.refresh(now: t0)
        let after1 = await provider.callCount()
        #expect(after1 == 1)

        // Second call exactly 5 seconds later — should run
        let t1 = t0.addingTimeInterval(5)
        await store.refresh(now: t1)
        let after2 = await provider.callCount()
        #expect(after2 == 2)
    }

    // MARK: one provider error does not abort tick

    @Test("one provider failure does NOT abort the tick")
    func oneProviderFailureDoesNotAbortTick() async {
        let idA = ProviderID(rawValue: "provA")
        let idB = ProviderID(rawValue: "provB")
        let now = Date()
        let snapA = makeSnapshot(providerID: idA, now: now)
        let provA = FakeProvider(id: idA, displayName: "ProviderA", result: .success(snapA))
        let provB = FakeProvider(id: idB, displayName: "ProviderB", result: .failure(URLError(.notConnectedToInternet)))
        let cache = AggFakeCacheStore()

        let store = AggregateStore(
            registry: [provA, provB],
            clock: VirtualClock(fixed: now),
            cache: cache,
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )

        await store.refresh(now: now)

        if case .ok = store.providers[idA]?.status { } else {
            Issue.record("Expected provA to have .ok status")
        }
        if let statusB = store.providers[idB]?.status {
            switch statusB {
            case .error, .stale: break // expected
            default: Issue.record("Expected provB to have .error or .stale status, got \(statusB)")
            }
        } else {
            Issue.record("Expected provB to have a status")
        }
        #expect(store.lastTick == now)
    }

    // MARK: cache write on success

    @Test("successful refresh writes cache atomically (D-08)")
    func successfulRefreshWritesCache() async {
        let id = ProviderID(rawValue: "openrouter")
        let now = Date()
        let snap = makeSnapshot(providerID: id, now: now)
        let provider = FakeProvider(id: id, displayName: "OpenRouter", result: .success(snap))
        let cache = AggFakeCacheStore()

        let store = AggregateStore(
            registry: [provider],
            clock: VirtualClock(fixed: now),
            cache: cache,
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )

        await store.refresh(now: now)

        #expect(cache.savedCallCount == 1)
        #expect(cache.lastSaved?[id] != nil)
    }

    // MARK: threshold dispatch

    @Test("refresh dispatches to NotificationManager (schedule is called after each refresh)")
    func refreshFiresThresholdDecisions() async {
        let id = ProviderID(rawValue: "openrouter")
        let now = Date()
        let snap = makeSnapshot(providerID: id, now: now)
        let provider = FakeProvider(id: id, displayName: "OpenRouter", result: .success(snap))
        let cache = AggFakeCacheStore()
        let spy = SpyNotificationManager()

        // ThresholdEngine stub always returns [] — we verify schedule is called once per refresh.
        let store = AggregateStore(
            registry: [provider],
            clock: VirtualClock(fixed: now),
            cache: cache,
            thresholds: ThresholdEngine(),
            notifications: spy
        )

        await store.refresh(now: now)

        // Stub ThresholdEngine returns [] — schedule must have been called exactly once
        #expect(spy.scheduledDecisions.count == 1)
        #expect(spy.scheduledDecisions.first == [])
    }

    // MARK: seedPlaceholder (B10)

    @Test("seedPlaceholder inserts a placeholder ProviderState (B10)")
    func seedPlaceholderInsertState() {
        let id = ProviderID(rawValue: "openrouter")
        let store = AggregateStore(
            registry: [],
            clock: VirtualClock(fixed: Date()),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )

        store.seedPlaceholder(providerID: id, displayName: "OpenRouter", status: .unauthenticated)

        let state = store.providers[id]
        #expect(state != nil)
        #expect(state?.snapshot == nil)
        #expect(state?.status == .unauthenticated)
        #expect(state?.displayName == "OpenRouter")
    }
}


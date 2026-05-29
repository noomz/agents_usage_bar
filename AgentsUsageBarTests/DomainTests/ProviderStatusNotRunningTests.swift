import Testing
import Foundation
@testable import AgentsUsageBar

/// Plan 04-01 / T-04-01-04 — locks `ProviderStatus.notRunning` semantic and
/// Codable round-trip. Also verifies the POLL-06 non-terminal re-probe invariant
/// (D-01): `.notRunning` must remain absent from `AggregateStore.performRefresh`'s
/// terminal-skip block so every 5-min tick re-probes the localhost runtime.
@Suite("ProviderStatusNotRunningTests")
struct ProviderStatusNotRunningTests {

    // MARK: - Distinctness

    @Test("notRunning is distinct from unauthenticated via Equatable")
    func notRunning_isDistinctFromUnauthenticated() {
        #expect(ProviderStatus.notRunning != ProviderStatus.unauthenticated)
    }

    // MARK: - Codable round-trip

    @Test("notRunning round-trips through JSONEncoder + JSONDecoder")
    func notRunning_codableRoundTrip() throws {
        let original = ProviderStatus.notRunning
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderStatus.self, from: data)
        #expect(decoded == original)
    }

    @Test("notRunning encodes and decodes preserving the same case (forward-compat gate)")
    func notRunning_isCodableForwardCompat() throws {
        let encoded = try JSONEncoder().encode(ProviderStatus.notRunning)
        let decoded = try JSONDecoder().decode(ProviderStatus.self, from: encoded)
        if case .notRunning = decoded {
            // correct — case preserved
        } else {
            Issue.record("Expected .notRunning after round-trip, got \(decoded)")
        }
    }

    // MARK: - POLL-06 non-terminal re-probe invariant (D-01 / RESEARCH §8.2)

    /// Proves `.notRunning` is non-terminal: seeds a stub actor whose `fetch(now:)`
    /// returns a snapshot with `lastStatus = .notRunning`. After the first
    /// `store.refresh(now:)` the stub's `fetchCallCount` is 1. After a second
    /// refresh with a clock advanced past the 5s debounce, the count becomes 2 —
    /// confirming `.notRunning` did NOT enter the POLL-06 terminal-skip block in
    /// `AggregateStore.performRefresh`.
    @Test("notRunning provider is re-probed on next refresh (POLL-06 non-terminal)")
    @MainActor
    func notRunning_providerIsReprobedOnNextRefresh() async {
        let id = ProviderID(rawValue: "ollama-test")
        let t0 = Date()

        // Snapshot carrying .notRunning semantics (server down, no tokens/cost/quota)
        let notRunningSnap = UsageSnapshot(
            providerID: id,
            asOf: t0,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: ["modelCount": "0"]
        )

        let stub = NotRunningStubProvider(id: id, snapshot: notRunningSnap)
        let cache = NotRunningFakeCache()

        let store = AggregateStore(
            registry: [stub],
            clock: VirtualClock(fixed: t0),
            cache: cache,
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )

        // First refresh — count becomes 1
        await store.refresh(now: t0)
        let countAfterFirst = await stub.callCount()
        #expect(countAfterFirst == 1)

        // Second refresh with clock advanced past 5s debounce — count must become 2
        // (.notRunning is non-terminal; the store must NOT skip it via POLL-06)
        let t1 = t0.addingTimeInterval(10)
        await store.refresh(now: t1)
        let countAfterSecond = await stub.callCount()
        #expect(countAfterSecond == 2,
            "Expected fetchCallCount == 2 after second refresh — .notRunning must not enter POLL-06 terminal-skip block")
    }
}

// MARK: - Test doubles (scoped to this file)

/// Stub actor: returns a fixed snapshot (status .notRunning) on every fetch.
private final actor NotRunningStubProvider: UsageProvider {
    nonisolated let id: ProviderID
    nonisolated let displayName: String = "OllamaTest"
    nonisolated let capabilities = ProviderCapabilities(
        hasQuota: false, hasCost: false, hasTokens: false, isLocal: true
    )

    private let snapshot: UsageSnapshot
    private(set) var fetchCallCount: Int = 0

    init(id: ProviderID, snapshot: UsageSnapshot) {
        self.id = id
        self.snapshot = snapshot
    }

    func status() -> ProviderStatus { .notRunning }

    func fetch(now: Date) async throws -> UsageSnapshot {
        fetchCallCount += 1
        return snapshot
    }

    func callCount() -> Int { fetchCallCount }
}

/// Minimal fake cache — no-op for this test.
private final class NotRunningFakeCache: CacheStore, @unchecked Sendable {
    func loadAll() -> [ProviderID: ProviderState] { [:] }
    func save(_ providers: [ProviderID: ProviderState]) {}
    func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? { nil }
    func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {}
    func transcriptOffset(forURL urlString: String) -> TranscriptOffset? { nil }
    func setTranscriptOffset(_ offset: TranscriptOffset) {}
    func allTranscriptOffsets() -> [String: TranscriptOffset] { [:] }
}

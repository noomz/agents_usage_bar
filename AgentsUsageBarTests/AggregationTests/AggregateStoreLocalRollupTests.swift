import Testing
@testable import AgentsUsageBar
import Foundation

// MARK: - AggregateStoreLocalRollupTests (Plan 04-08 Task 3)
//
// Regression lock for Phase 3 STATE #86 D-07 rollup exclusion.
// AggregateStore.rollupTotals() must skip providers whose
// capabilities.hasTokens == false — this includes all three local providers
// (Ollama, LM Studio, llama.cpp) as well as Gemini.
//
// These tests ensure no future refactor accidentally includes local providers'
// fabricated tokensToday/costTodayUSD values in the cross-provider "Today total".

// MARK: - Shared test doubles (mirroring AppDependenciesCodexGeminiRegistrationTests)

private final actor StubRollupProvider: UsageProvider {
    nonisolated let id: ProviderID
    nonisolated let displayName: String
    nonisolated let capabilities: ProviderCapabilities
    private let snapshotToReturn: UsageSnapshot

    init(
        id: ProviderID,
        displayName: String,
        capabilities: ProviderCapabilities,
        snapshot: UsageSnapshot
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.snapshotToReturn = snapshot
    }

    func status() -> ProviderStatus { .ok(lastSuccess: snapshotToReturn.asOf) }

    func fetch(now: Date) async throws -> UsageSnapshot {
        snapshotToReturn
    }
}

private final class StubRollupCacheStore: CacheStore, @unchecked Sendable {
    var providers: [ProviderID: ProviderState] = [:]
    private var offsets: [String: TranscriptOffset] = [:]

    func loadAll() -> [ProviderID: ProviderState] { providers }
    func save(_ providers: [ProviderID: ProviderState]) { self.providers = providers }
    func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? { nil }
    func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {}
    func transcriptOffset(forURL urlString: String) -> TranscriptOffset? { offsets[urlString] }
    func setTranscriptOffset(_ offset: TranscriptOffset) { offsets[offset.url] = offset }
    func allTranscriptOffsets() -> [String: TranscriptOffset] { offsets }
}

// MARK: - Helpers

private func makeSnapshot(
    providerID: ProviderID,
    asOf: Date,
    tokens: Int?,
    costUSD: Decimal?
) -> UsageSnapshot {
    UsageSnapshot(
        providerID: providerID,
        asOf: asOf,
        tokensToday: tokens,
        costTodayUSD: costUSD,
        balanceUSD: nil,
        quota: nil,
        raw: [:]
    )
}

private let remoteCapabilities = ProviderCapabilities(
    hasQuota: true,
    hasCost: true,
    hasTokens: true,
    isLocal: false
)

private let localCapabilities = ProviderCapabilities(
    hasQuota: false,
    hasCost: false,
    hasTokens: false,
    isLocal: true
)

@MainActor
@Suite("AggregateStoreLocalRollupTests")
struct AggregateStoreLocalRollupTests {

    let now = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Test 1: local providers' fabricated tokens/cost are excluded from rollup

    @Test("rollupTotals_excludesLocalProviders")
    func rollupTotals_excludesLocalProviders() async {
        // Codex: remote, hasTokens=true → contributes to total
        let stubCodex = StubRollupProvider(
            id: .codex,
            displayName: "Codex",
            capabilities: remoteCapabilities,
            snapshot: makeSnapshot(providerID: .codex, asOf: now, tokens: 1000, costUSD: Decimal(string: "0.50"))
        )
        // Ollama: local, hasTokens=false → MUST be excluded even with fabricated tokens
        let stubOllama = StubRollupProvider(
            id: .ollama,
            displayName: "Ollama",
            capabilities: localCapabilities,
            snapshot: makeSnapshot(providerID: .ollama, asOf: now, tokens: 999, costUSD: Decimal(string: "77.00"))
        )
        // LM Studio: local, hasTokens=false → MUST be excluded
        let stubLMStudio = StubRollupProvider(
            id: .lmstudio,
            displayName: "LM Studio",
            capabilities: localCapabilities,
            snapshot: makeSnapshot(providerID: .lmstudio, asOf: now, tokens: 888, costUSD: Decimal(string: "55.00"))
        )

        let store = AggregateStore(
            registry: [stubCodex, stubOllama, stubLMStudio],
            clock: VirtualClock(fixed: now),
            cache: StubRollupCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        await store.refresh(now: now)

        // D-07: only Codex's values should appear in totals
        #expect(store.totals.tokens == 1000, "Local providers' fabricated tokens must be excluded")
        #expect(store.totals.costUSD == Decimal(string: "0.50"), "Local providers' fabricated cost must be excluded")
    }

    // MARK: - Test 2: all-local registry → totals are zero

    @Test("rollupTotals_emptyLocalsContribute0")
    func rollupTotals_emptyLocalsContribute0() async {
        let stubOllama = StubRollupProvider(
            id: .ollama,
            displayName: "Ollama",
            capabilities: localCapabilities,
            snapshot: makeSnapshot(providerID: .ollama, asOf: now, tokens: 500, costUSD: Decimal(string: "10.00"))
        )
        let stubLMStudio = StubRollupProvider(
            id: .lmstudio,
            displayName: "LM Studio",
            capabilities: localCapabilities,
            snapshot: makeSnapshot(providerID: .lmstudio, asOf: now, tokens: 300, costUSD: Decimal(string: "5.00"))
        )

        let store = AggregateStore(
            registry: [stubOllama, stubLMStudio],
            clock: VirtualClock(fixed: now),
            cache: StubRollupCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        await store.refresh(now: now)

        // No remote providers → totals must be zero
        #expect(store.totals.tokens == 0)
        #expect(store.totals.costUSD == Decimal(0))
    }

    // MARK: - Test 3: hasAnyQuotaOnlyProvider is true when any local is registered

    @Test("hasAnyQuotaOnlyProvider_returnsTrueForAnyLocal")
    func hasAnyQuotaOnlyProvider_returnsTrueForAnyLocal() {
        let stubLlamaCpp = StubRollupProvider(
            id: .llamacpp,
            displayName: "llama.cpp",
            capabilities: localCapabilities,
            snapshot: makeSnapshot(providerID: .llamacpp, asOf: now, tokens: nil, costUSD: nil)
        )
        let store = AggregateStore(
            registry: [stubLlamaCpp],
            clock: VirtualClock(fixed: now),
            cache: StubRollupCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        // Phase 3 STATE #86: hasAnyQuotaOnlyProvider fires TotalsHeaderView footnote
        #expect(store.hasAnyQuotaOnlyProvider == true)
    }

    // MARK: - Test 4: all three locals excluded alongside a remote provider

    @Test("rollupTotals_allThreeLocalsExcluded_withOneRemote")
    func rollupTotals_allThreeLocalsExcluded_withOneRemote() async {
        let stubRemote = StubRollupProvider(
            id: .claude,
            displayName: "Claude",
            capabilities: remoteCapabilities,
            snapshot: makeSnapshot(providerID: .claude, asOf: now, tokens: 2500, costUSD: Decimal(string: "1.25"))
        )
        let stubOllama = StubRollupProvider(
            id: .ollama, displayName: "Ollama",
            capabilities: localCapabilities,
            snapshot: makeSnapshot(providerID: .ollama, asOf: now, tokens: 100, costUSD: Decimal(string: "1.00"))
        )
        let stubLMStudio = StubRollupProvider(
            id: .lmstudio, displayName: "LM Studio",
            capabilities: localCapabilities,
            snapshot: makeSnapshot(providerID: .lmstudio, asOf: now, tokens: 200, costUSD: Decimal(string: "2.00"))
        )
        let stubLlamaCpp = StubRollupProvider(
            id: .llamacpp, displayName: "llama.cpp",
            capabilities: localCapabilities,
            snapshot: makeSnapshot(providerID: .llamacpp, asOf: now, tokens: 300, costUSD: Decimal(string: "3.00"))
        )

        let store = AggregateStore(
            registry: [stubRemote, stubOllama, stubLMStudio, stubLlamaCpp],
            clock: VirtualClock(fixed: now),
            cache: StubRollupCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        await store.refresh(now: now)

        // Only Claude's values — all three locals excluded
        #expect(store.totals.tokens == 2500)
        #expect(store.totals.costUSD == Decimal(string: "1.25"))
        #expect(store.hasAnyQuotaOnlyProvider == true)
    }
}

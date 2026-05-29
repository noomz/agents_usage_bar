import Testing
@testable import AgentsUsageBar
import Foundation

// MARK: - AppDependenciesCodexGeminiRegistrationTests (Plan 03-08 Task 3)
//
// Plan 03-08 exercises two production behaviours that are easiest to test
// against a hand-built registry of test-double UsageProviders (mirroring
// Phase 2's AggregateStoreTests pattern):
//
//   1. AggregateStore.init populates `hasTokensByID` from each registered
//      provider's `capabilities.hasTokens`, exposing `hasAnyQuotaOnlyProvider`.
//   2. AggregateStore.rollupTotals() skips providers whose hasTokens is false,
//      so Gemini's tokensToday/costTodayUSD never leak into the cross-provider
//      total (D-07).
//
// Plus a smoke test against `AppDependencies.makeProduction()` which asserts
// the registration paths run without throwing and seed the expected
// placeholder rows when the test host has no Codex / Gemini credentials.
//
// Composition-root integration (live HTTP, live credential files) is the
// explicit Plan 03-09 UAT boundary; this suite verifies the actor-layer
// contract directly.

// MARK: - Test doubles (mirror Phase 2 FakeProvider)

private final actor StubProvider: UsageProvider {
    nonisolated let id: ProviderID
    nonisolated let displayName: String
    nonisolated let capabilities: ProviderCapabilities

    private var snapshotToReturn: UsageSnapshot

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

private final class StubCacheStore: CacheStore, @unchecked Sendable {
    var providers: [ProviderID: ProviderState] = [:]
    private var offsets: [String: TranscriptOffset] = [:]

    func loadAll() -> [ProviderID: ProviderState] { providers }
    func save(_ providers: [ProviderID: ProviderState]) { self.providers = providers }
    func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? { nil }
    func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {}

    func transcriptOffset(forURL urlString: String) -> TranscriptOffset? {
        offsets[urlString]
    }
    func setTranscriptOffset(_ offset: TranscriptOffset) {
        offsets[offset.url] = offset
    }
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

@MainActor
@Suite("AppDependenciesCodexGeminiRegistrationTests")
struct AppDependenciesCodexGeminiRegistrationTests {

    // MARK: - Fixtures

    let now = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Test 1: hasAnyQuotaOnlyProvider true when registry includes a hasTokens=false provider

    @Test("hasAnyQuotaOnlyProvider_isTrue_whenRegistryIncludesGemini")
    func hasAnyQuotaOnlyProvider_true() {
        let openrouter = StubProvider(
            id: .openrouter,
            displayName: "OpenRouter",
            capabilities: ProviderCapabilities(hasQuota: true, hasCost: true, hasTokens: false, isLocal: false),
            snapshot: makeSnapshot(providerID: .openrouter, asOf: now, tokens: nil, costUSD: Decimal(string: "1.50"))
        )
        let codex = StubProvider(
            id: .codex,
            displayName: "Codex",
            capabilities: ProviderCapabilities(hasQuota: true, hasCost: true, hasTokens: true, isLocal: false),
            snapshot: makeSnapshot(providerID: .codex, asOf: now, tokens: 1000, costUSD: Decimal(string: "0.50"))
        )
        let gemini = StubProvider(
            id: .gemini,
            displayName: "Gemini",
            capabilities: ProviderCapabilities(hasQuota: true, hasCost: false, hasTokens: false, isLocal: false),
            snapshot: makeSnapshot(providerID: .gemini, asOf: now, tokens: nil, costUSD: nil)
        )
        let store = AggregateStore(
            registry: [openrouter, codex, gemini],
            clock: VirtualClock(fixed: now),
            cache: StubCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        #expect(store.hasAnyQuotaOnlyProvider == true)
    }

    // MARK: - Test 2: Codex-only-tokens registry → hasAnyQuotaOnlyProvider depends on OpenRouter

    @Test("hasAnyQuotaOnlyProvider_reflectsOpenRouterCapabilities_whenNoGemini")
    func hasAnyQuotaOnlyProvider_noGemini() {
        // OpenRouter's real capabilities (Plan 01.04) have hasTokens=false.
        // When OpenRouter is in the registry without Gemini, the property
        // is still TRUE because OpenRouter itself is quota-only by capability.
        let openrouter = StubProvider(
            id: .openrouter,
            displayName: "OpenRouter",
            capabilities: ProviderCapabilities(hasQuota: true, hasCost: true, hasTokens: false, isLocal: false),
            snapshot: makeSnapshot(providerID: .openrouter, asOf: now, tokens: nil, costUSD: Decimal(string: "1.50"))
        )
        let codex = StubProvider(
            id: .codex,
            displayName: "Codex",
            capabilities: ProviderCapabilities(hasQuota: true, hasCost: true, hasTokens: true, isLocal: false),
            snapshot: makeSnapshot(providerID: .codex, asOf: now, tokens: 1000, costUSD: Decimal(string: "0.50"))
        )
        let store = AggregateStore(
            registry: [openrouter, codex],
            clock: VirtualClock(fixed: now),
            cache: StubCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        // OpenRouter hasTokens=false → property true.
        #expect(store.hasAnyQuotaOnlyProvider == true)
    }

    // MARK: - Test 3: rollupTotals excludes Gemini's tokens/costs (D-07)

    @Test("rollupTotals_excludesQuotaOnlyProvider")
    func rollupTotals_excludesQuotaOnly() async {
        let codex = StubProvider(
            id: .codex,
            displayName: "Codex",
            capabilities: ProviderCapabilities(hasQuota: true, hasCost: true, hasTokens: true, isLocal: false),
            snapshot: makeSnapshot(providerID: .codex, asOf: now, tokens: 1000, costUSD: Decimal(string: "0.50"))
        )
        // Gemini hasTokens=false BUT the stub fabricates tokensToday=500 +
        // costTodayUSD=99.00 so we can verify D-07 actually skips it.
        let gemini = StubProvider(
            id: .gemini,
            displayName: "Gemini",
            capabilities: ProviderCapabilities(hasQuota: true, hasCost: false, hasTokens: false, isLocal: false),
            snapshot: makeSnapshot(providerID: .gemini, asOf: now, tokens: 500, costUSD: Decimal(string: "99.00"))
        )
        let store = AggregateStore(
            registry: [codex, gemini],
            clock: VirtualClock(fixed: now),
            cache: StubCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        await store.refresh(now: now)

        // D-07: Gemini's tokens (500) + cost ($99.00) are EXCLUDED.
        #expect(store.totals.tokens == 1000)
        #expect(store.totals.costUSD == Decimal(string: "0.50"))
    }

    // MARK: - Test 4: Cache-restored ProviderState (no registered actor) defaults to included

    @Test("rollupTotals_includesProviderNotInRegistry_byDefault")
    func rollupTotals_includesProviderNotInRegistry() async {
        // Edge case: providers loaded from cache without a corresponding
        // actor in the registry default to INCLUDED in totals — they only
        // contribute 0 anyway since their snapshot.tokensToday is nil for
        // any cache restored from a registered provider that previously had
        // hasTokens=false. Verified by a cache-restored Codex (hasTokens=true
        // by capability but no actor in registry) carrying real numbers.
        let codexState = ProviderState(
            id: .codex,
            displayName: "Codex",
            snapshot: makeSnapshot(providerID: .codex, asOf: now, tokens: 2000, costUSD: Decimal(string: "1.25")),
            status: .ok(lastSuccess: now),
            lastSuccess: now
        )
        let cache = StubCacheStore()
        cache.providers = [.codex: codexState]
        let store = AggregateStore(
            registry: [],   // empty — no hasTokensByID entries
            clock: VirtualClock(fixed: now),
            cache: cache,
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        // Provider not in `hasTokensByID` (== `nil`) is included — totals
        // reflect its values.
        #expect(store.totals.tokens == 2000)
        #expect(store.totals.costUSD == Decimal(string: "1.25"))
        // And since `hasTokensByID` is empty, the property is false.
        #expect(store.hasAnyQuotaOnlyProvider == false)
    }

    // MARK: - Test 5: Empty registry → hasAnyQuotaOnlyProvider false; totals zero

    @Test("emptyRegistry_noQuotaOnlyProvider")
    func emptyRegistry_noQuotaOnly() {
        let store = AggregateStore(
            registry: [],
            clock: VirtualClock(fixed: now),
            cache: StubCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        #expect(store.hasAnyQuotaOnlyProvider == false)
        #expect(store.totals.tokens == 0)
        #expect(store.totals.costUSD == Decimal(0))
    }

    // MARK: - Test 6: Smoke — AppDependencies.makeProduction() runs without throwing

    /// Plan 03-08 smoke test — exercises the composition root end-to-end.
    ///
    /// Two production paths exist for each new provider (Codex / Gemini):
    ///
    ///   (a) Provider REGISTERS — added to `registry` array, NOT seeded into
    ///       `store.providers` until first refresh. Visible in the popover
    ///       after the first poll tick.
    ///   (b) Provider does NOT register (config disabled OR credentials
    ///       absent) — Plan 03-08 seeds a placeholder row into
    ///       `store.providers` immediately so the popover always shows
    ///       Codex/Gemini in the list with `.unauthenticated` status.
    ///
    /// On a clean CI runner (no `~/.codex/*`, no `~/.gemini/*`) path (b)
    /// fires for both. On a dev machine with the actual CLIs installed
    /// path (a) may fire and the provider will NOT be in `store.providers`
    /// until refresh runs. Either path is acceptable — the invariant under
    /// test is that `makeProduction()` runs to completion without throwing
    /// AND seeds the always-on placeholders (openrouter).
    @Test("makeProduction_smokeTest_runsWithoutThrowing")
    func makeProduction_smoke() {
        let deps = AppDependencies.makeProduction()
        let ids = Set(deps.store.providers.keys)
        // OpenRouter MUST be placeholder-seeded on a test runner (no env
        // OPENROUTER_API_KEY); this is the only invariant the smoke test
        // can assert cross-environment.
        #expect(ids.contains(ProviderID.openrouter))
        // Scheduler + powerObserver are non-optional; merely reaching this
        // line proves they were constructed without throwing.
        _ = deps.scheduler
        _ = deps.powerObserver
    }
}

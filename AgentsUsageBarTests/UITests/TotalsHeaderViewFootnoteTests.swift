import Foundation
import Testing
@testable import AgentsUsageBar

/// Plan 03-07 Task 3 — TotalsHeaderView "Total excludes quota-only providers"
/// footnote contract (D-07).
///
/// The footnote renders when `AggregateStore.hasAnyQuotaOnlyProvider` is `true`
/// — i.e. when any registered provider's `capabilities.hasTokens == false`
/// (Plan 03-08 introduced the accessor). The footnote is NOT rendered when
/// every registered provider reports tokens, so Phase 1's OpenRouter-only
/// build (also `hasTokens == false`) is the boundary case that exercises the
/// rule.
@Suite("Plan 03-07 Task 3 — TotalsHeaderView footnote (D-07)")
@MainActor
struct TotalsHeaderViewFootnoteTests {

    // MARK: - Source-grep contract

    @Test("TotalsHeaderView source contains the footnote literal 'excludes quota-only providers'")
    func source_containsFootnoteLiteral() throws {
        let src = try Self.totalsHeaderViewSource()
        #expect(src.contains("excludes quota-only providers"),
                "TotalsHeaderView must render 'Total excludes quota-only providers' when hasAnyQuotaOnlyProvider is true (D-07)")
    }

    @Test("TotalsHeaderView reads hasAnyQuotaOnlyProvider from the store")
    func source_readsHasAnyQuotaOnlyProvider() throws {
        let src = try Self.totalsHeaderViewSource()
        #expect(src.contains("hasAnyQuotaOnlyProvider"),
                "TotalsHeaderView must consult store.hasAnyQuotaOnlyProvider to decide whether to render the footnote")
    }

    @Test("AggregateStore exposes hasTokensByID + hasAnyQuotaOnlyProvider (Plan 03-08 precondition)")
    func aggregateStore_exposesQuotaOnlyAccessor() throws {
        let src = try Self.aggregateStoreSource()
        #expect(src.contains("hasTokensByID"),
                "AggregateStore must carry hasTokensByID (Plan 03-08 — Plan 03-07 only consumes it)")
        #expect(src.contains("hasAnyQuotaOnlyProvider"),
                "AggregateStore must expose hasAnyQuotaOnlyProvider for TotalsHeaderView (Plan 03-08 / Plan 03-07)")
    }

    // MARK: - Behavioural assertions (hasAnyQuotaOnlyProvider semantics)

    @Test("Empty registry -> hasAnyQuotaOnlyProvider == false; no footnote condition")
    func emptyRegistry_noQuotaOnlyProvider() {
        let store = makeStore(registry: [])
        #expect(store.hasAnyQuotaOnlyProvider == false)
    }

    @Test("Registry with a quota-only provider (hasTokens=false) -> hasAnyQuotaOnlyProvider == true")
    func quotaOnlyProvider_triggersFootnote() {
        let store = makeStore(registry: [
            StubProvider(id: .gemini, displayName: "Gemini",
                         capabilities: ProviderCapabilities(hasQuota: true, hasCost: false, hasTokens: false, isLocal: false))
        ])
        #expect(store.hasAnyQuotaOnlyProvider == true)
    }

    @Test("Registry with only tokens-reporting provider -> hasAnyQuotaOnlyProvider == false")
    func tokenReportingOnly_noFootnote() {
        let store = makeStore(registry: [
            StubProvider(id: .codex, displayName: "Codex",
                         capabilities: ProviderCapabilities(hasQuota: true, hasCost: true, hasTokens: true, isLocal: false))
        ])
        #expect(store.hasAnyQuotaOnlyProvider == false)
    }

    @Test("Mixed registry (tokens-reporting + quota-only) -> hasAnyQuotaOnlyProvider == true")
    func mixedRegistry_oneQuotaOnly_triggersFootnote() {
        let store = makeStore(registry: [
            StubProvider(id: .codex, displayName: "Codex",
                         capabilities: ProviderCapabilities(hasQuota: true, hasCost: true, hasTokens: true, isLocal: false)),
            StubProvider(id: .gemini, displayName: "Gemini",
                         capabilities: ProviderCapabilities(hasQuota: true, hasCost: false, hasTokens: false, isLocal: false)),
        ])
        #expect(store.hasAnyQuotaOnlyProvider == true)
    }

    // MARK: - Test infrastructure

    private func makeStore(registry: [any UsageProvider]) -> AggregateStore {
        AggregateStore(
            registry: registry,
            clock: SystemClock(),
            cache: NoopCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
    }

    static func totalsHeaderViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repoRoot
            .appendingPathComponent("AgentsUsageBar")
            .appendingPathComponent("UI")
            .appendingPathComponent("TotalsHeaderView.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    static func aggregateStoreSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repoRoot
            .appendingPathComponent("AgentsUsageBar")
            .appendingPathComponent("Aggregation")
            .appendingPathComponent("AggregateStore.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }
}

/// Minimal `UsageProvider` stub used to seed the AggregateStore registry with
/// known capabilities for the hasAnyQuotaOnlyProvider semantics tests.
private actor StubProvider: UsageProvider {
    nonisolated let id: ProviderID
    nonisolated let displayName: String
    nonisolated let capabilities: ProviderCapabilities

    init(id: ProviderID, displayName: String, capabilities: ProviderCapabilities) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
    }

    func status() -> ProviderStatus { .unauthenticated }

    func fetch(now: Date) async throws -> UsageSnapshot {
        UsageSnapshot(
            providerID: id, asOf: now,
            tokensToday: nil, costTodayUSD: nil, balanceUSD: nil,
            quota: nil, raw: [:], quotaWindows: nil, tooltipLabel: nil
        )
    }
}

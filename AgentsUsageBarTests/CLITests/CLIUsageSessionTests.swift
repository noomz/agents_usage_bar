import Foundation
import Testing
@testable import AgentsUsageBar

private actor FakeUsageProvider: UsageProvider {
    nonisolated let id: ProviderID
    nonisolated let displayName: String
    nonisolated let capabilities: ProviderCapabilities
    var snapshot: UsageSnapshot
    var throwError: Error?

    init(id: ProviderID, displayName: String, capabilities: ProviderCapabilities, snapshot: UsageSnapshot) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.snapshot = snapshot
    }

    func status() -> ProviderStatus { .ok(lastSuccess: snapshot.asOf) }
    func fetch(now: Date) async throws -> UsageSnapshot {
        if let throwError { throw throwError }
        return snapshot
    }
}

private final class MemCache: CacheStore, @unchecked Sendable {
    var stored: [ProviderID: ProviderState] = [:]
    var saves = 0
    func loadAll() -> [ProviderID: ProviderState] { stored }
    func save(_ providers: [ProviderID: ProviderState]) { saves += 1; stored = providers }
    func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? { nil }
    func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {}
    func transcriptOffset(forURL urlString: String) -> TranscriptOffset? { nil }
    func setTranscriptOffset(_ offset: TranscriptOffset) {}
    func allTranscriptOffsets() -> [String: TranscriptOffset] { [:] }
}

@Suite("CLIUsageSession")
@MainActor
struct CLIUsageSessionTests {

    @Test("live fetch does not write cache")
    func liveDoesNotSave() async {
        let now = Date()
        let snap = UsageSnapshot(
            providerID: .claude, asOf: now, tokensToday: 5,
            costTodayUSD: 1, balanceUSD: nil, quota: nil, raw: [:]
        )
        let provider = FakeUsageProvider(
            id: .claude, displayName: "Claude",
            capabilities: ProviderCapabilities(hasQuota: true, hasCost: true, hasTokens: true, isLocal: false),
            snapshot: snap
        )
        let cache = MemCache()
        let session = CLIUsageSession(providers: [provider], cache: cache, clock: SystemClock())
        let report = await session.fetch(filter: .enabled, cached: false, now: now)
        #expect(cache.saves == 0)
        #expect(report.source == .live)
        #expect(report.providers.count == 1)
        #expect(report.totals.tokens == 5)
    }

    @Test("cached path reads store and skips actors")
    func cachedReadsStore() async {
        let now = Date()
        let state = ProviderState(
            id: .codex,
            displayName: "Codex",
            snapshot: UsageSnapshot(
                providerID: .codex, asOf: now, tokensToday: 9,
                costTodayUSD: 3, balanceUSD: nil, quota: nil, raw: [:]
            ),
            status: .ok(lastSuccess: now),
            lastSuccess: now
        )
        let cache = MemCache()
        cache.stored = [.codex: state]
        let session = CLIUsageSession(providers: [], cache: cache)
        let report = await session.fetch(filter: .all, cached: true, now: now)
        #expect(report.source == .cached)
        #expect(report.providers.first?.snapshot?.tokensToday == 9)
        #expect(cache.saves == 0)
    }

    @Test("filter one provider")
    func filterOne() async {
        let now = Date()
        func snap(_ id: ProviderID) -> UsageSnapshot {
            UsageSnapshot(providerID: id, asOf: now, tokensToday: 1, costTodayUSD: 1, balanceUSD: nil, quota: nil, raw: [:])
        }
        let claude = FakeUsageProvider(
            id: .claude, displayName: "Claude",
            capabilities: ProviderCapabilities(hasQuota: true, hasCost: true, hasTokens: true, isLocal: false),
            snapshot: snap(.claude)
        )
        let grok = FakeUsageProvider(
            id: .grok, displayName: "Grok",
            capabilities: ProviderCapabilities(hasQuota: true, hasCost: false, hasTokens: false, isLocal: false),
            snapshot: snap(.grok)
        )
        let session = CLIUsageSession(providers: [claude, grok])
        let report = await session.fetch(filter: .one(.grok), cached: false, now: now)
        #expect(report.providers.map(\.id) == [.grok])
    }

    @Test("enabled filter honors isEnabled")
    func enabledFilter() async {
        let now = Date()
        let snap = UsageSnapshot(
            providerID: .claude, asOf: now, tokensToday: 1,
            costTodayUSD: 1, balanceUSD: nil, quota: nil, raw: [:]
        )
        let claude = FakeUsageProvider(
            id: .claude, displayName: "Claude",
            capabilities: ProviderCapabilities(hasQuota: true, hasCost: true, hasTokens: true, isLocal: false),
            snapshot: snap
        )
        let session = CLIUsageSession(providers: [claude], isEnabled: { _ in false })
        let report = await session.fetch(filter: .enabled, cached: false, now: now)
        #expect(report.providers.isEmpty)
    }
}

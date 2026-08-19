import Foundation
import Testing
@testable import AgentsUsageBar

actor FakeGrokBillingClient: GrokBillingClientProtocol {
    enum Step {
        case ok(GrokBillingResponse)
        case fail(Error)
    }

    private var queue: [Step]
    private(set) var callCount = 0

    init(_ steps: [Step]) {
        self.queue = steps
    }

    func fetchCredits() async throws -> GrokBillingResponse {
        callCount += 1
        guard !queue.isEmpty else {
            throw GrokBillingError.billingEndpointFailed(status: 500)
        }
        switch queue.removeFirst() {
        case .ok(let r): return r
        case .fail(let e): throw e
        }
    }
}

@Suite("GrokBillingProviderTests")
struct GrokBillingProviderTests {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    @Test func happy_path_quota_and_no_today_tokens() async throws {
        let billing = GrokBillingResponse(
            creditUsagePercent: 42.5,
            monthlyLimit: 1000,
            includedUsed: 425,
            prepaidBalance: 12.5,
            subscriptionTier: "supergrok"
        )
        let client = FakeGrokBillingClient([.ok(billing)])
        let provider = GrokBillingProvider(client: client, clock: SystemClock())
        let snap = try await provider.fetch(now: now)
        #expect(snap.providerID == .grok)
        #expect(snap.tokensToday == nil)
        #expect(snap.costTodayUSD == nil)
        #expect(snap.quota?.used == 425)
        #expect(snap.quota?.limit == 1000)
        #expect(snap.balanceUSD == Decimal(12.5))
        #expect(snap.tooltipLabel == "supergrok")
        #expect(snap.quotaUsageCaption == "43% used")
        #expect(provider.capabilities.hasTokens == false)
        #expect(provider.capabilities.hasQuota == true)
        if case .ok = await provider.status() {
            // ok
        } else {
            Issue.record("expected .ok status")
        }
    }

    @Test func live_weekly_payload_surfaces_percent_and_period() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/billing-config-weekly.json"))
        let billing = try JSONDecoder().decode(GrokBillingResponse.self, from: data)
        let client = FakeGrokBillingClient([.ok(billing)])
        let provider = GrokBillingProvider(client: client, clock: SystemClock())
        let snap = try await provider.fetch(now: now)
        #expect(snap.quotaUsageCaption == "24% used · weekly")
        #expect(snap.tokensToday == nil)
        #expect(snap.costTodayUSD == nil)
        #expect(snap.balanceUSD == nil)
        #expect(snap.tooltipLabel == "GrokBuild · Weekly")
        #expect(snap.quotaWindows?.first?.resetsAt != nil)
    }

    @Test func unauthorized_is_muted_not_thrown() async throws {
        let client = FakeGrokBillingClient([.fail(GrokBillingError.unauthorized(status: 401))])
        let provider = GrokBillingProvider(client: client, clock: SystemClock())
        let snap = try await provider.fetch(now: now)
        #expect(snap.quota == nil)
        #expect(snap.raw["status"] == "no-data-yet")
        #expect(await provider.status() == .unauthenticated)
    }

    @Test func empty_payload_after_success_keeps_last_good_quota() async throws {
        let good = GrokBillingResponse(
            creditUsagePercent: 41,
            periodLabel: "weekly",
            productLabel: "GrokBuild"
        )
        let client = FakeGrokBillingClient([.ok(good), .ok(GrokBillingResponse())])
        let provider = GrokBillingProvider(client: client, clock: SystemClock())
        _ = try await provider.fetch(now: now)
        let kept = try await provider.fetch(now: now.addingTimeInterval(300))
        #expect(kept.quotaUsageCaption == "41% used · weekly")
        #expect(kept.tooltipLabel == "GrokBuild · Weekly")
        if case .ok = await provider.status() {
            // keep serving last good rather than flipping to empty "no limit"
        } else {
            Issue.record("expected .ok while retaining last good snapshot")
        }
    }

    @Test func unauthorized_after_success_keeps_last_good_quota() async throws {
        let good = GrokBillingResponse(creditUsagePercent: 41, periodLabel: "weekly")
        let client = FakeGrokBillingClient([
            .ok(good),
            .fail(GrokBillingError.unauthorized(status: 401)),
        ])
        let provider = GrokBillingProvider(client: client, clock: SystemClock())
        _ = try await provider.fetch(now: now)
        let kept = try await provider.fetch(now: now.addingTimeInterval(300))
        #expect(kept.quotaUsageCaption == "41% used · weekly")
        #expect(await provider.status() != .unauthenticated)
    }

    @Test func transient_failure_degrades_without_throw_and_keeps_cache() async throws {
        let billing = GrokBillingResponse(monthlyLimit: 100, includedUsed: 10, subscriptionTier: "supergrok")
        let client = FakeGrokBillingClient([
            .ok(billing),
            .fail(GrokBillingError.billingEndpointFailed(status: 503)),
        ])
        let provider = GrokBillingProvider(client: client, clock: SystemClock())
        _ = try await provider.fetch(now: now)
        let degraded = try await provider.fetch(now: now.addingTimeInterval(60))
        #expect(degraded.quota?.used == 10)
        #expect(degraded.raw["note"] == ThresholdEngine.degradedTag)
        #expect(degraded.tokensToday == nil)
        if case .stale = await provider.status() {
            // ok
        } else {
            Issue.record("expected stale after transient failure")
        }
    }

    @Test func capabilities_exclude_from_today_totals() {
        // Structural lock: hasTokens false is what AggregateStore.rollupTotals keys on.
        let provider = GrokBillingProvider(
            client: FakeGrokBillingClient([]),
            clock: SystemClock()
        )
        #expect(provider.capabilities.hasTokens == false)
        #expect(provider.capabilities.hasCost == false)
        #expect(provider.capabilities.isLocal == false)
        #expect(provider.id == .grok)
        #expect(provider.displayName == "Grok")
    }

    @Test func client_source_never_reveals_secret() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "AgentsUsageBar/Providers/Grok/GrokBillingClient.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("revealForRequest") == false)
    }
}

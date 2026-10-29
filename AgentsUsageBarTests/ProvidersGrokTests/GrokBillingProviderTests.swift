import Foundation
import Testing
@testable import AgentsUsageBar

actor FakeGrokManagementClient: GrokManagementClientProtocol {
    private let snapshot: GrokManagementSnapshot
    private let error: Error?

    init(_ snapshot: GrokManagementSnapshot) {
        self.snapshot = snapshot
        self.error = nil
    }

    init(error: Error) {
        self.snapshot = GrokManagementSnapshot(remainingUSD: nil, costTodayUSD: nil)
        self.error = error
    }

    func fetch(now: Date) async throws -> GrokManagementSnapshot {
        if let error { throw error }
        return snapshot
    }
}

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
        #expect(provider.capabilities.hasTokens == true)
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

    @Test func capabilities_tokens_true_cost_true() {
        let provider = GrokBillingProvider(
            client: FakeGrokBillingClient([]),
            clock: SystemClock()
        )
        #expect(provider.capabilities.hasTokens == true)
        #expect(provider.capabilities.hasCost == true)
        #expect(provider.capabilities.isLocal == false)
        #expect(provider.id == .grok)
        #expect(provider.displayName == "Grok")
    }

    @Test func empty_cli_with_management_spend_is_not_no_limit() async throws {
        let cli = FakeGrokBillingClient([.ok(GrokBillingResponse())])
        let mgmt = FakeGrokManagementClient(
            GrokManagementSnapshot(remainingUSD: Decimal(string: "12.50"), costTodayUSD: Decimal(string: "1.25"))
        )
        let provider = GrokBillingProvider(client: cli, management: mgmt, clock: SystemClock())
        let snap = try await provider.fetch(now: now)
        #expect(snap.quota == nil)
        #expect(snap.costTodayUSD == Decimal(string: "1.25"))
        #expect(snap.balanceUSD == Decimal(string: "12.50"))
        #expect(snap.raw["source"] == "management")
        #expect(snap.tooltipLabel == "API")
        if case .ok = await provider.status() {
            // ok
        } else {
            Issue.record("expected .ok when management data exists")
        }
    }

    @Test func cli_quota_overlays_management_spend() async throws {
        let billing = GrokBillingResponse(creditUsagePercent: 41, periodLabel: "weekly")
        let cli = FakeGrokBillingClient([.ok(billing)])
        let mgmt = FakeGrokManagementClient(
            GrokManagementSnapshot(remainingUSD: 8, costTodayUSD: 2)
        )
        let provider = GrokBillingProvider(client: cli, management: mgmt, clock: SystemClock())
        let snap = try await provider.fetch(now: now)
        #expect(snap.raw["period"] == "weekly")
        #expect(snap.quota != nil)
        #expect(snap.costTodayUSD == 2)
        #expect(snap.balanceUSD == 8)
    }

    @Test func pi_jsonl_xai_beats_management_zero() async throws {
        let root = try makeGrokJSONLRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeGrokJSONL(
            to: root.appendingPathComponent("s.jsonl"),
            lines: [
                grokAssistantLine(now: now, provider: "xai", tokens: 1000, cost: "1.25"),
            ]
        )
        let cache = FakeCacheStore()
        let provider = GrokBillingProvider(
            client: FakeGrokBillingClient([.ok(GrokBillingResponse())]),
            management: FakeGrokManagementClient(
                GrokManagementSnapshot(remainingUSD: 0, costTodayUSD: 0)
            ),
            clock: SystemClock(),
            scanner: TranscriptDirectoryScanner(),
            reader: PiSessionReader(),
            sessionRoots: { [root] },
            cache: cache
        )
        let snap = try await provider.fetch(now: now)
        #expect(snap.tokensToday == 1000)
        #expect(snap.costTodayUSD == Decimal(string: "1.25"))
        #expect(snap.balanceUSD == 0)
        #expect(snap.raw["source"]?.contains("pi-jsonl") == true)
        #expect(snap.quota == nil)
    }

    @Test func pi_jsonl_ignores_openrouter_and_drm_swap() async throws {
        let root = try makeGrokJSONLRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeGrokJSONL(
            to: root.appendingPathComponent("s.jsonl"),
            lines: [
                grokAssistantLine(now: now, provider: "xai", tokens: 1000, cost: "1.25"),
                grokAssistantLine(now: now, provider: "openrouter", tokens: 500, cost: "9.99"),
                grokAssistantLine(now: now, provider: "DRM-SWAP", tokens: 33482, cost: "0"),
            ]
        )
        let provider = GrokBillingProvider(
            client: FakeGrokBillingClient([.ok(GrokBillingResponse())]),
            management: FakeGrokManagementClient(
                GrokManagementSnapshot(remainingUSD: 0, costTodayUSD: 0)
            ),
            clock: SystemClock(),
            scanner: TranscriptDirectoryScanner(),
            reader: PiSessionReader(),
            sessionRoots: { [root] },
            cache: FakeCacheStore()
        )
        let snap = try await provider.fetch(now: now)
        #expect(snap.tokensToday == 1000)
        #expect(snap.costTodayUSD == Decimal(string: "1.25"))
    }

    @Test func grok_offset_key_does_not_overwrite_pi_local_url_key() async throws {
        let root = try makeGrokJSONLRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("s.jsonl")
        try writeGrokJSONL(
            to: fileURL,
            lines: [
                grokAssistantLine(now: now, provider: "xai", tokens: 10, cost: "0.01"),
            ]
        )
        let cache = FakeCacheStore()
        let prior = TranscriptOffset(url: fileURL.absoluteString, byteOffset: 42, lastModified: now)
        cache.setTranscriptOffset(prior)
        let provider = GrokBillingProvider(
            client: FakeGrokBillingClient([.ok(GrokBillingResponse())]),
            clock: SystemClock(),
            scanner: TranscriptDirectoryScanner(),
            reader: PiSessionReader(),
            sessionRoots: { [root] },
            cache: cache
        )
        _ = try await provider.fetch(now: now)
        #expect(cache.transcriptOffset(forURL: fileURL.absoluteString)?.byteOffset == 42)
        let grokKey = "grok:" + fileURL.absoluteString
        #expect(cache.transcriptOffset(forURL: grokKey) != nil)
        #expect(cache.transcriptOffset(forURL: grokKey)?.byteOffset != 42)
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

private func makeGrokJSONLRoot() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("GrokBillingProviderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

private func writeGrokJSONL(to dest: URL, lines: [String]) throws {
    let body = lines.joined(separator: "\n") + "\n"
    try body.write(to: dest, atomically: true, encoding: .utf8)
}

private func grokAssistantLine(now: Date, provider: String, tokens: Int, cost: String) -> String {
    let ts = grokISO(now)
    return """
    {"type":"message","timestamp":"\(ts)","message":{"role":"assistant","provider":"\(provider)","model":"grok-3","usage":{"totalTokens":\(tokens),"cost":{"total":\(cost)}}}}
    """.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func grokISO(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

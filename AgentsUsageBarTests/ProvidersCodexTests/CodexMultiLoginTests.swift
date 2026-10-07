import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("CodexMultiLoginTests", .serialized)
struct CodexMultiLoginTests {

    @Test func twoLogins_headerKeepsRolloutSpend_andChildrenUsePrimaryOnly() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try pin("2026-10-07T02:40:00.000Z")
        try writeWindowlessToday(under: root)

        let plus = cliproxyLogin(accountId: plusID, token: "test-token-plus", plan: "plus")
        let team = cliproxyLogin(accountId: teamID, token: "test-token-team", plan: "team")
        let oauth = RoutingOAuth(responses: [
            plusID: .success(usage(
                plan: "plus",
                primaryPercent: 20,
                primaryReset: 1_800_000_000,
                secondaryPercent: 90,
                secondaryReset: 1_900_000_000
            )),
            teamID: .success(usage(
                plan: "team",
                primaryPercent: 70,
                primaryReset: 1_800_003_600,
                secondaryPercent: 10,
                secondaryReset: 1_900_003_600
            )),
        ])
        let provider = makeProvider(root: root, oauth: oauth, logins: [team, plus])

        let snap = try await provider.fetch(now: now)
        let accounts = try #require(snap.accounts)
        #expect(accounts.map(\.name) == ["plus", "team"])
        #expect(accounts.allSatisfy { $0.costTodayUSD == nil })
        #expect(snap.tokensToday == 18404)
        #expect(snap.costTodayUSD == expectedRolloutCost)
        #expect(snap.quotaWindows == nil)
        #expect(snap.raw["source"] == "codex-accounts")
        #expect(!String(describing: snap.raw).contains("test-token"))
        expectClose(snap.quota?.fraction, 0.70)

        let plusRow = try #require(accounts.first { $0.name == "plus" })
        expectClose(plusRow.quota?.fraction, 0.20)
        #expect(plusRow.quotaWindows?.map(\.name) == ["primary", "secondary"])
        #expect(plusRow.quotaWindows?[0].duration == 18_000)
        #expect(plusRow.quotaWindows?[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(plusRow.quotaWindows?[1].duration == 604_800)
        expectClose(plusRow.quotaWindows?[1].utilization, 0.90)

        let teamRow = try #require(accounts.first { $0.name == "team" })
        expectClose(teamRow.quota?.fraction, 0.70)
        #expect(teamRow.quotaWindows?[0].resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(CodexLoginDiscovery.markedAccountName(accounts) == "team")

        let ids = await oauth.explicitAccountIDs.compactMap { $0 }
        #expect(Set(ids) == Set([plusID, teamID]))
        #expect(ids.count == 2)
        #expect(Set(await oauth.explicitTokens) == Set(["test-token-plus", "test-token-team"]))
        #expect(await oauth.parameterlessCalls == 0)
        await expectOK(provider)
    }

    @Test func twoLogins_oneWhamFailure_keepsTheOtherRowAndDoesNotThrow() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try pin("2026-10-07T02:40:00.000Z")
        try writeWindowlessToday(under: root)

        let oauth = RoutingOAuth(responses: [
            plusID: .success(usage(
                plan: "plus",
                primaryPercent: 20,
                primaryReset: 1_800_000_000,
                secondaryPercent: 90,
                secondaryReset: 1_900_000_000
            )),
            teamID: .failure(.usageEndpointFailed(status: 429)),
        ])
        let provider = makeProvider(
            root: root,
            oauth: oauth,
            logins: [
                cliproxyLogin(accountId: plusID, token: "test-token-plus", plan: "plus"),
                cliproxyLogin(accountId: teamID, token: "test-token-team", plan: "team"),
            ]
        )

        let snap = try await provider.fetch(now: now)
        let accounts = try #require(snap.accounts)
        #expect(accounts.map(\.name) == ["plus", "team"])
        let plusRow = try #require(accounts.first { $0.name == "plus" })
        let teamRow = try #require(accounts.first { $0.name == "team" })
        expectClose(plusRow.quota?.fraction, 0.20)
        #expect(teamRow.quota == nil)
        #expect(teamRow.quotaWindows == nil)
        #expect(teamRow.costTodayUSD == nil)
        expectClose(snap.quota?.fraction, 0.20)
        #expect(snap.quotaWindows == nil)
        #expect(snap.tokensToday == 18404)
        #expect(snap.raw["source"] == "codex-accounts")
        #expect(CodexLoginDiscovery.markedAccountName(accounts) == "plus")
        let failedIDs = await oauth.explicitAccountIDs.compactMap { $0 }
        #expect(Set(failedIDs) == Set([plusID, teamID]))
        #expect(failedIDs.count == 2)
        #expect(await oauth.parameterlessCalls == 0)
        await expectOK(provider)
    }

    @Test func twoLogins_missingPrimary_doesNotUseSecondaryAsUsageQuota() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oauth = RoutingOAuth(responses: [
            plusID: .success(usage(
                plan: "plus",
                primaryPercent: 40,
                primaryReset: 1_800_000_000,
                secondaryPercent: 5,
                secondaryReset: 1_900_000_000
            )),
            teamID: .success(usage(
                plan: "team",
                primaryPercent: nil,
                primaryReset: nil,
                secondaryPercent: 80,
                secondaryReset: 1_900_000_000
            )),
        ])
        let provider = makeProvider(
            root: root,
            oauth: oauth,
            logins: [
                cliproxyLogin(accountId: plusID, token: "test-token-plus", plan: "plus"),
                cliproxyLogin(accountId: teamID, token: "test-token-team", plan: "team"),
            ]
        )

        let snap = try await provider.fetch(now: Date(timeIntervalSince1970: 1_700_000_000))
        let accounts = try #require(snap.accounts)
        let teamRow = try #require(accounts.first { $0.name == "team" })
        #expect(teamRow.quota == nil)
        #expect(teamRow.quotaWindows?.map(\.name) == ["secondary"])
        expectClose(teamRow.quotaWindows?.first?.utilization, 0.80)
        expectClose(snap.quota?.fraction, 0.40)
        #expect(snap.quotaWindows == nil)
        #expect(CodexLoginDiscovery.markedAccountName(accounts) == "plus")
        await expectOK(provider)
    }

    @Test func twoLogins_noPrimaryFraction_headerQuotaIsNil() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oauth = RoutingOAuth(responses: [
            plusID: .success(usage(
                plan: "plus",
                primaryPercent: nil,
                primaryReset: nil,
                secondaryPercent: 15,
                secondaryReset: 1_900_000_000
            )),
            teamID: .failure(.usageEndpointFailed(status: 500)),
        ])
        let provider = makeProvider(
            root: root,
            oauth: oauth,
            logins: [
                cliproxyLogin(accountId: plusID, token: "test-token-plus", plan: "plus"),
                cliproxyLogin(accountId: teamID, token: "test-token-team", plan: "team"),
            ]
        )

        let snap = try await provider.fetch(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snap.accounts?.count == 2)
        #expect(snap.quota == nil)
        #expect(snap.quotaWindows == nil)
        #expect(snap.tokensToday == nil)
        #expect(CodexLoginDiscovery.markedAccountName(snap.accounts ?? []) == nil)
        let calledIDs = await oauth.explicitAccountIDs.compactMap { $0 }
        #expect(Set(calledIDs) == Set([plusID, teamID]))
        #expect(calledIDs.count == 2)
        await expectOK(provider)
    }

    @Test func twoLogins_liveRolloutWindows_doNotReplacePerLoginWham() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try pin("2026-04-24T12:00:00.000Z")
        try writeLiveRollout(under: root)

        let oauth = RoutingOAuth(responses: [
            plusID: .success(usage(plan: "plus", primaryPercent: 11, primaryReset: 1_800_000_000)),
            teamID: .success(usage(plan: "team", primaryPercent: 22, primaryReset: 1_800_003_600)),
        ])
        let provider = makeProvider(
            root: root,
            oauth: oauth,
            logins: [
                cliproxyLogin(accountId: plusID, token: "test-token-plus", plan: "plus"),
                cliproxyLogin(accountId: teamID, token: "test-token-team", plan: "team"),
            ]
        )

        let snap = try await provider.fetch(now: now)
        #expect(snap.tokensToday == 556_469)
        #expect(snap.raw["source"] == "codex-accounts")
        #expect(snap.quotaWindows == nil)
        expectClose(snap.quota?.fraction, 0.22)
        #expect(snap.accounts?.map(\.name) == ["plus", "team"])
        #expect(await oauth.explicitAccountIDs.count == 2)
        #expect(await oauth.parameterlessCalls == 0)
    }

    @Test func twoLogins_authJSONLabelUsesWhamPlanType() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = CodexDiscoveredLogin(
            accountId: proID,
            accessToken: Secret("test-token-pro"),
            email: nil,
            planSuffix: nil,
            source: .authJSON
        )
        let oauth = RoutingOAuth(responses: [
            plusID: .success(usage(plan: "plus", primaryPercent: 10, primaryReset: 1_800_000_000)),
            proID: .success(usage(plan: "Pro", primaryPercent: 30, primaryReset: 1_800_003_600)),
        ])
        let provider = makeProvider(
            root: root,
            oauth: oauth,
            logins: [
                cliproxyLogin(accountId: plusID, token: "test-token-plus", plan: "plus"),
                auth,
            ]
        )

        let snap = try await provider.fetch(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snap.accounts?.map(\.name) == ["plus", "pro"])
        expectClose(snap.accounts?.first { $0.name == "pro" }?.quota?.fraction, 0.30)
        #expect(!String(describing: snap.raw).contains("test-token-pro"))
    }

    @Test func markedAccount_highestPrimary_thenSoonerReset_thenAlphabeticalLabel() {
        let sooner = Date(timeIntervalSince1970: 1_800_000_000)
        let later = Date(timeIntervalSince1970: 1_800_003_600)

        #expect(CodexLoginDiscovery.markedAccountName([
            row("plus", primary: 0.20, reset: sooner),
            row("team", primary: 0.70, reset: later),
        ]) == "team")

        #expect(CodexLoginDiscovery.markedAccountName([
            row("team", primary: 0.40, reset: later),
            row("plus", primary: 0.40, reset: sooner),
        ]) == "plus")

        #expect(CodexLoginDiscovery.markedAccountName([
            row("plus", primary: 0.50, reset: nil),
            row("team", primary: 0.50, reset: sooner),
        ]) == "team")

        #expect(CodexLoginDiscovery.markedAccountName([
            row("team", primary: 0.50, reset: nil),
            row("plus", primary: 0.50, reset: nil),
        ]) == "plus")

        #expect(CodexLoginDiscovery.markedAccountName([
            row("plus", primary: nil, reset: nil),
            row("team", primary: nil, reset: nil),
        ]) == nil)

        #expect(CodexLoginDiscovery.markedAccountName([
            UsageSnapshot.AccountUsage(name: "plus", costTodayUSD: nil, quota: nil, quotaWindows: nil),
            row("team", primary: 0.10, reset: later),
        ]) == "team")
    }
}

// MARK: - Fixtures

private let plusID = "aaaaaaaa-1111-aaaa-aaaa-aaaaaaaaaaaa"
private let teamID = "bbbbbbbb-2222-bbbb-bbbb-bbbbbbbbbbbb"
private let proID = "cccccccc-3333-cccc-cccc-cccccccccccc"

private let expectedRolloutCost = CodexModelPricing.testPricing.cost(
    inputTokens: 18_000,
    cachedInputTokens: 0,
    outputTokens: 404,
    reasoningOutputTokens: 0,
    modelID: nil
)

private func expectClose(_ actual: Double?, _ expected: Double) {
    #expect(abs((actual ?? -1) - expected) < 0.000_1)
}

private func expectOK(_ provider: CodexJSONLProvider) async {
    let status = await provider.status()
    if case .ok = status {} else {
        Issue.record("Expected .ok, got \(status)")
    }
}

private func row(_ name: String, primary: Double?, reset: Date?) -> UsageSnapshot.AccountUsage {
    let quota = primary.map { Quota(used: $0, limit: 1, remaining: max(0, 1 - $0)) }
    let windows: [QuotaWindow]? = primary == nil
        ? nil
        : [QuotaWindow(name: "primary", utilization: primary, resetsAt: reset, duration: 18_000)]
    return UsageSnapshot.AccountUsage(name: name, costTodayUSD: nil, quota: quota, quotaWindows: windows)
}

private func usage(
    plan: String,
    primaryPercent: Double?,
    primaryReset: Int?,
    secondaryPercent: Double? = nil,
    secondaryReset: Int? = nil
) -> CodexUsageResponse {
    let primary: CodexUsageResponse.Window? =
        (primaryPercent == nil && primaryReset == nil)
        ? nil
        : CodexUsageResponse.Window(
            usedPercent: primaryPercent,
            resetAt: primaryReset,
            limitWindowSeconds: 18_000
        )
    let secondary: CodexUsageResponse.Window? =
        (secondaryPercent == nil && secondaryReset == nil)
        ? nil
        : CodexUsageResponse.Window(
            usedPercent: secondaryPercent,
            resetAt: secondaryReset,
            limitWindowSeconds: 604_800
        )
    return CodexUsageResponse(
        planType: plan,
        rateLimit: CodexUsageResponse.RateLimit(primaryWindow: primary, secondaryWindow: secondary),
        credits: nil
    )
}

private func cliproxyLogin(accountId: String, token: String, plan: String) -> CodexDiscoveredLogin {
    CodexDiscoveredLogin(
        accountId: accountId,
        accessToken: Secret(token),
        email: "\(plan)@example.com",
        planSuffix: plan,
        source: .cliproxy(filename: "codex-\(String(accountId.prefix(8)))-\(plan)@example.com-\(plan).json")
    )
}

private func makeProvider(
    root: URL,
    oauth: RoutingOAuth,
    logins: [CodexDiscoveredLogin]
) -> CodexJSONLProvider {
    CodexJSONLProvider(
        scannerFactory: scannerFactory(root: root),
        reader: TranscriptReader(),
        pricing: .testPricing,
        oauth: oauth,
        cache: StubMultiCacheStore(),
        clock: SystemClock(),
        logins: { logins }
    )
}

private actor RoutingOAuth: CodexOAuthClientProtocol {
    private let responses: [String: Result<CodexUsageResponse, CodexOAuthError>]
    private(set) var explicitTokens: [String] = []
    private(set) var explicitAccountIDs: [String?] = []
    private(set) var parameterlessCalls = 0

    init(responses: [String: Result<CodexUsageResponse, CodexOAuthError>]) {
        self.responses = responses
    }

    func fetchUsage() async throws -> CodexUsageResponse {
        parameterlessCalls += 1
        throw CodexOAuthError.usageEndpointFailed(status: 999)
    }

    func fetchUsage(token: Secret, accountId: String?) async throws -> CodexUsageResponse {
        explicitTokens.append(token.revealForRequest())
        explicitAccountIDs.append(accountId)
        guard let accountId, let scripted = responses[accountId] else {
            throw CodexOAuthError.usageEndpointFailed(status: 404)
        }
        return try scripted.get()
    }
}

private final class StubMultiCacheStore: CacheStore, @unchecked Sendable {
    private var transcripts: [String: TranscriptOffset] = [:]

    func loadAll() -> [ProviderID: ProviderState] { [:] }
    func save(_ providers: [ProviderID: ProviderState]) {}
    func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? { nil }
    func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {}
    func transcriptOffset(forURL urlString: String) -> TranscriptOffset? { transcripts[urlString] }
    func setTranscriptOffset(_ offset: TranscriptOffset) { transcripts[offset.url] = offset }
    func setTranscriptOffsets(_ offsets: [TranscriptOffset]) {
        for offset in offsets { transcripts[offset.url] = offset }
    }
    func allTranscriptOffsets() -> [String: TranscriptOffset] { transcripts }
}

private func makeEmptyRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexMultiLogin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func dateDir(under root: URL, year: Int, month: Int, day: Int) throws -> URL {
    let dir = root
        .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func scannerFactory(root: URL) -> CodexRolloutScannerFactory {
    let calendar = Calendar(identifier: .gregorian)
    return { now in CodexRolloutScanner(now: now, calendar: calendar, root: root) }
}

private func pin(_ iso: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try #require(formatter.date(from: iso))
}

private func writeWindowlessToday(under root: URL) throws {
    let today = """
    {"timestamp":"2026-10-07T02:34:31.992Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":18000,"cached_input_tokens":0,"output_tokens":404,"reasoning_output_tokens":0,"total_tokens":18404}},"rate_limits":{"limit_id":"codex","primary":null,"secondary":null}}}
    """
    let todayDir = try dateDir(under: root, year: 2026, month: 10, day: 7)
    try today.write(to: todayDir.appendingPathComponent("cliproxy.jsonl"), atomically: true, encoding: .utf8)
}

private func writeLiveRollout(under root: URL) throws {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("codex-rollout-2026-fixture.jsonl")
    let raw = try String(contentsOf: here, encoding: .utf8)
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let firstThree = lines.prefix(3).joined(separator: "\n") + "\n"
    let todayDir = try dateDir(under: root, year: 2026, month: 4, day: 24)
    try firstThree.write(to: todayDir.appendingPathComponent("rollout-A.jsonl"), atomically: true, encoding: .utf8)
}

private extension CodexModelPricing {
    static let testPricing = CodexModelPricing(
        schemaVersion: 1,
        lastUpdated: "test",
        default: .init(inputPerMToken: 0.750, outputPerMToken: 3.000, cachedInputPerMToken: 0.025),
        models: [:]
    )
}

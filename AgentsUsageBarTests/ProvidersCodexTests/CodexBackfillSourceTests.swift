import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("CodexBackfillSourceTests")
struct CodexBackfillSourceTests {

    /// UTC+9, so a UTC timestamp near midnight lands on a different local day.
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// A Buddhist legacy calendar, as on a Thai-locale host: rollout directories still use the
    /// Gregorian year.
    private static let dayKeys: DayKeyOwner = {
        let clock = VirtualClock(fixed: ISO8601DateFormatter().date(from: "2026-10-22T03:00:00Z")!)
        return DayKeyOwner(clock: clock, timeZone: tokyo, legacyCalendar: Calendar(identifier: .buddhist))
    }()

    /// $1 per million uncached input tokens; cached input and output free.
    private static let pricing = CodexModelPricing(
        schemaVersion: 1, lastUpdated: "test",
        default: .init(inputPerMToken: 1, outputPerMToken: 0, cachedInputPerMToken: 0),
        models: [:])

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func tokenCount(_ timestamp: String, total: Int) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(total)}}}}"#
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func source(root: URL?, logins: [CodexDiscoveredLogin] = []) -> CodexBackfillSource {
        CodexBackfillSource(pricing: Self.pricing, dayKeys: Self.dayKeys, root: { root }, logins: { logins })
    }

    @Test("each event's rise in the session total lands on its local day, a session past midnight splits (V10, I10)")
    func recordsPerDay() async throws {
        let root = try makeRoot()
        try write([
            // 22:00 on 10-19 in Tokyo.
            tokenCount("2026-10-19T13:00:00.000Z", total: 100_000),
            #"{"timestamp":"2026-10-19T13:30:00.000Z","type":"response_item","payload":{"type":"message"}}"#,
            // 01:00 on 10-20 in Tokyo.
            tokenCount("2026-10-19T16:00:00.000Z", total: 300_000),
            tokenCount("2026-10-19T16:00:01.000Z", total: 300_000),
        ], to: root.appending(path: "2026/10/19/rollout-a.jsonl"))
        try write([
            tokenCount("2026-10-20T02:00:00.000Z", total: 50_000),
            tokenCount("2026-10-20T03:00:00.000Z", total: 80_000),
            // A dropped total starts the count again.
            tokenCount("2026-10-20T04:00:00.000Z", total: 20_000),
            #"{"timestamp":"2026-10-20T05:00:00.000Z","type":"event_msg","payload":{"type":"token_cou"#,
        ], to: root.appending(path: "2026/10/20/rollout-b.jsonl"))
        try write([tokenCount("2026-10-21T02:00:00.000Z", total: 7)], to: root.appending(path: "2026/10/21/rollout-c.jsonl"))

        let records = try await source(root: root).records(for: ["2026-10-20"])

        #expect(records == [
            "2026-10-20": DayRecord(
                provider: .codex, tokens: 300_000, costUSD: Money(Decimal(string: "0.3")!),
                costEstimated: true, origin: .backfilled),
        ])
    }

    @Test("a day without rollouts is a zero, and no price table leaves cost unknown (V7, V30)")
    func zeroAndUnpriced() async throws {
        let root = try makeRoot()
        let unpriced = CodexBackfillSource(pricing: nil, dayKeys: Self.dayKeys, root: { root }, logins: { [] })
        #expect(try await source(root: root).records(for: ["2026-10-18"]) == [
            "2026-10-18": DayRecord(provider: .codex, tokens: 0, costUSD: Money(0), costEstimated: true, origin: .backfilled),
        ])
        #expect(try await unpriced.records(for: ["2026-10-18"]) == [
            "2026-10-18": DayRecord(provider: .codex, tokens: 0, costUSD: nil, costEstimated: false, origin: .backfilled),
        ])
    }

    @Test("reach is the whole retention window with a sessions root and nil without one (V28)")
    func reach() async throws {
        #expect(await source(root: try makeRoot()).reachDays() == HistoryStore.retainedDays)
        #expect(await source(root: nil).reachDays() == nil)
    }

    @Test("no login is one metered default account; logins are assumed subscriptions with their ids (I6, V62)")
    func accounts() async throws {
        let none = await source(root: nil).accounts()
        #expect(none.map(\.name) == ["default"])
        #expect(none.map(\.accountInfo) == [AccountInfo(billingModel: .metered)])

        let logins = [
            CodexDiscoveredLogin(accountId: "id-a", accessToken: Secret("t-a"), email: nil, planSuffix: "plus",
                                 source: .cliproxy(filename: "codex-a-plus.json")),
            CodexDiscoveredLogin(accountId: "id-b", accessToken: Secret("t-b"), email: nil, planSuffix: "team",
                                 source: .cliproxy(filename: "codex-b-team.json")),
        ]
        let found = await source(root: nil, logins: logins).accounts()
        #expect(found.compactMap(\.accountInfo).sorted { ($0.plan ?? "") < ($1.plan ?? "") } == [
            AccountInfo(billingModel: .subscription, plan: "plus", accountID: "id-a"),
            AccountInfo(billingModel: .subscription, plan: "team", accountID: "id-b"),
        ])
    }
}

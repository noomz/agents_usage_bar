import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("ClaudeBackfillSourceTests")
struct ClaudeBackfillSourceTests {

    /// UTC+9, so a UTC timestamp near midnight lands on a different local day.
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private static let dayKeys: DayKeyOwner = {
        let clock = VirtualClock(fixed: ISO8601DateFormatter().date(from: "2026-10-22T03:00:00Z")!)
        return DayKeyOwner(clock: clock, timeZone: tokyo, legacyCalendar: Calendar(identifier: .buddhist))
    }()

    /// $1 per million input tokens, $2 per million output tokens, cache free.
    private static let pricing = ClaudeModelPricing(
        schemaVersion: 1, lastUpdated: "test",
        default: .init(inputPer1M: 1, outputPer1M: 2, cacheWritePer1M: 0, cacheReadPer1M: 0),
        models: [:])

    private func makeHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.resolvingSymlinksInPath()
    }

    private func line(_ timestamp: String, request: String, input: Int, output: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"\#(request)","message":{"model":"claude-test","role":"assistant","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func source(home: URL, roots: [URL]) -> ClaudeBackfillSource {
        ClaudeBackfillSource(pricing: Self.pricing, dayKeys: Self.dayKeys, roots: { roots }, home: home)
    }

    @Test("usage lands on its local day across roots, each request counted once, a day without usage is a zero (V10, V30, I10)")
    func recordsPerDay() async throws {
        let home = try makeHome()
        let claudeRoot = home.appending(path: ".claude/projects")
        let shared = home.appending(path: ".ccs/shared/context-groups/default/projects")
        let instance = home.appending(path: ".ccs/instances/work")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        // The ccs layout: an instance's projects dir is a symlink to the shared group.
        try FileManager.default.createSymbolicLink(at: instance.appending(path: "projects"), withDestinationURL: shared)

        try write([
            // 23:30 on 10-20 in Tokyo.
            line("2026-10-20T14:30:00.000Z", request: "r1", input: 1_000_000, output: 0),
            // 00:30 on 10-21 in Tokyo.
            line("2026-10-20T15:30:00.000Z", request: "r2", input: 0, output: 1_000_000),
        ], to: shared.appending(path: "proj/a.jsonl"))
        try write([
            line("2026-10-20T15:30:00.000Z", request: "r2", input: 0, output: 1_000_000),
            line("2026-10-21T01:00:00.000Z", request: "r3", input: 2_000_000, output: 0),
            // Today in Tokyo, not asked for.
            line("2026-10-21T16:00:00.000Z", request: "r4", input: 9, output: 9),
        ], to: claudeRoot.appending(path: "proj/b.jsonl"))

        let roots = [claudeRoot, shared, instance.appending(path: "projects")]
        let records = try await source(home: home, roots: roots).records(for: ["2026-10-19", "2026-10-20", "2026-10-21"])

        #expect(records == [
            "2026-10-19": DayRecord(provider: .claude, tokens: 0, costUSD: Money(0), costEstimated: true, origin: .backfilled),
            "2026-10-20": DayRecord(provider: .claude, tokens: 1_000_000, costUSD: Money(1), costEstimated: true, origin: .backfilled),
            "2026-10-21": DayRecord(provider: .claude, tokens: 3_000_000, costUSD: Money(4), costEstimated: true, origin: .backfilled),
        ])
    }

    @Test("reach is 29 days with a transcript root on disk and nil with none (V28)")
    func reach() async throws {
        let home = try makeHome()
        let root = home.appending(path: ".claude/projects")
        #expect(await source(home: home, roots: [root]).reachDays() == nil)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(await source(home: home, roots: [root]).reachDays() == 29)
    }

    @Test("accounts are default and each ccs instance with a .claude.json, billed from it (I6, V62)")
    func accounts() async throws {
        let home = try makeHome()
        try #"{"oauthAccount":{"organizationType":"claude_max"}}"#.write(
            to: home.appending(path: ".claude.json"), atomically: true, encoding: .utf8)
        try write(["{}"], to: home.appending(path: ".ccs/instances/work/.claude.json"))
        try FileManager.default.createDirectory(
            at: home.appending(path: ".ccs/instances/personal"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appending(path: ".ccs/instances/.locks"), withIntermediateDirectories: true)

        let accounts = await source(home: home, roots: []).accounts()
        #expect(accounts.map(\.name) == ["default", "work"])
        #expect(accounts.map(\.accountInfo) == [
            AccountInfo(billingModel: .subscription, plan: "max"),
            AccountInfo(billingModel: .metered),
        ])
        #expect(accounts.allSatisfy { $0.costTodayUSD == nil && $0.quotaWindows == nil })
    }
}

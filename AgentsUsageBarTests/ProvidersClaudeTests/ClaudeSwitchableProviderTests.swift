import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("ClaudeSwitchableProvider")
struct ClaudeSwitchableProviderTests {

    // MARK: - Source box (mutable @Sendable selector for delegation tests)

    /// A tiny mutable box so a single facade's `@Sendable` source closure can be flipped
    /// between fetches. `@unchecked Sendable` is safe here — the test drives all reads and
    /// writes serially on one task.
    private final class SourceBox: @unchecked Sendable {
        var value: ClaudeUsageSource
        init(_ value: ClaudeUsageSource) { self.value = value }
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeSession(_ name: String, json: String, mtime: Date, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("\(name).json")
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    /// A JSONL provider over an empty roots directory — returns a valid snapshot with a
    /// non-nil (zero) `tokensToday` and no quota. Delegation is fingerprinted by COST:
    /// the hook feed carries a known cost the JSONL path can never produce. (Tokens no
    /// longer distinguish the modes — hook mode grafts the JSONL `tokensToday` on.)
    private func makeJSONLProvider(rootsEmptyDir: URL) -> ClaudeJSONLProvider {
        let pricing = ClaudeModelPricing(
            schemaVersion: 1,
            lastUpdated: "test",
            default: .init(inputPer1M: 3.0, outputPer1M: 15.0, cacheWritePer1M: 3.75, cacheReadPer1M: 0.30),
            models: [:]
        )
        return ClaudeJSONLProvider(
            reader: TranscriptReader(),
            scanner: TranscriptDirectoryScanner(),
            pricing: pricing,
            oauth: nil,
            cache: NoopCacheStore(),
            clock: SystemClock(),
            roots: { [rootsEmptyDir] }
        )
    }

    // MARK: - Delegation

    @Test func hookSourceDelegatesToHookProvider() async throws {
        let hookDir = try makeTempDir()
        let jsonlRoots = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: hookDir)
            try? FileManager.default.removeItem(at: jsonlRoots)
        }

        let now = Date()
        try writeSession("s1", json: #"{ "session_id": "s1", "cost": { "total_cost_usd": 3.5 } }"#,
                         mtime: now, in: hookDir)

        let facade = ClaudeSwitchableProvider(
            jsonl: makeJSONLProvider(rootsEmptyDir: jsonlRoots),
            hookProvider: ClaudeHookProvider(feedDir: hookDir),
            source: { .hook }
        )

        let snap = try await facade.fetch(now: now)
        // Hook fingerprint: cost from the feed. Tokens are HYBRID — grafted from the
        // JSONL delegate (0 over an empty root), so the row never renders "—" tokens.
        #expect(snap.costTodayUSD == Decimal(string: "3.5"))
        #expect(snap.tokensToday == 0)
        #expect(snap.providerID == .claude)
    }

    @Test func sessionReadsSourceDelegatesToJSONLProvider() async throws {
        let hookDir = try makeTempDir()
        let jsonlRoots = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: hookDir)
            try? FileManager.default.removeItem(at: jsonlRoots)
        }

        let now = Date()
        // Hook feed has data too — but sessionReads must ignore it entirely.
        try writeSession("s1", json: #"{ "session_id": "s1", "cost": { "total_cost_usd": 3.5 } }"#,
                         mtime: now, in: hookDir)

        let facade = ClaudeSwitchableProvider(
            jsonl: makeJSONLProvider(rootsEmptyDir: jsonlRoots),
            hookProvider: ClaudeHookProvider(feedDir: hookDir),
            source: { .sessionReads }
        )

        let snap = try await facade.fetch(now: now)
        // JSONL fingerprint: tokensToday is a number (0 over an empty root), never nil.
        #expect(snap.tokensToday == 0)
        #expect(snap.costTodayUSD != Decimal(string: "3.5"))
        #expect(snap.providerID == .claude)
    }

    @Test func flippingSourceFlipsDelegation() async throws {
        let hookDir = try makeTempDir()
        let jsonlRoots = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: hookDir)
            try? FileManager.default.removeItem(at: jsonlRoots)
        }

        let now = Date()
        try writeSession("s1", json: #"{ "session_id": "s1", "cost": { "total_cost_usd": 7.25 } }"#,
                         mtime: now, in: hookDir)

        let box = SourceBox(.sessionReads)
        let facade = ClaudeSwitchableProvider(
            jsonl: makeJSONLProvider(rootsEmptyDir: jsonlRoots),
            hookProvider: ClaudeHookProvider(feedDir: hookDir),
            source: { box.value }
        )

        // sessionReads first.
        let first = try await facade.fetch(now: now)
        #expect(first.tokensToday == 0)

        // Flip to hook; same facade instance now delegates to the hook provider.
        // (Tokens stay 0 — hybrid graft from the JSONL delegate — so cost is the flag.)
        box.value = .hook
        let second = try await facade.fetch(now: now)
        #expect(second.tokensToday == 0)
        #expect(second.costTodayUSD == Decimal(string: "7.25"))
    }

    // MARK: - Status mirroring

    @Test func statusMirrorsDelegateOnSuccess() async throws {
        let hookDir = try makeTempDir()
        let jsonlRoots = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: hookDir)
            try? FileManager.default.removeItem(at: jsonlRoots)
        }

        let now = Date()
        try writeSession("s1", json: #"{ "session_id": "s1", "cost": { "total_cost_usd": 1.0 } }"#,
                         mtime: now, in: hookDir)

        let facade = ClaudeSwitchableProvider(
            jsonl: makeJSONLProvider(rootsEmptyDir: jsonlRoots),
            hookProvider: ClaudeHookProvider(feedDir: hookDir),
            source: { .hook }
        )

        _ = try await facade.fetch(now: now)
        #expect(await facade.status() == .ok(lastSuccess: now))
    }

    @Test func statusMirrorsDelegateOnError() async throws {
        // Empty hook feed → hook provider throws → facade mirrors the delegate's error status.
        let hookDir = try makeTempDir()
        let jsonlRoots = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: hookDir)
            try? FileManager.default.removeItem(at: jsonlRoots)
        }

        let facade = ClaudeSwitchableProvider(
            jsonl: makeJSONLProvider(rootsEmptyDir: jsonlRoots),
            hookProvider: ClaudeHookProvider(feedDir: hookDir),
            source: { .hook }
        )

        await #expect(throws: ClaudeHookError.noFeedData) {
            _ = try await facade.fetch(now: Date())
        }

        // Facade status is an error (mirrors the hook delegate's post-throw status).
        let status = await facade.status()
        if case .error = status {
            // expected
        } else {
            Issue.record("expected .error status, got \(status)")
        }
    }

    // MARK: - Billing model and plan (SPEC I6, V25)

    private func writeClaudeJSON(_ json: String, account: String, home: URL) throws {
        let url = ClaudeAccountPlans.claudeJSON(for: account, home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    @Test func claudeJSONOrganizationTypeIsThePlan() {
        let info = ClaudeAccountPlans.info(fromClaudeJSON: Data(#"{"oauthAccount":{"organizationType":"claude_max"},"projects":{}}"#.utf8))
        #expect(info == AccountInfo(billingModel: .subscription, plan: "max"))
        #expect(ClaudeAccountPlans.info(fromClaudeJSON: Data(#"{"projects":{}}"#.utf8)) == AccountInfo(billingModel: .metered))
        #expect(ClaudeAccountPlans.info(fromClaudeJSON: Data("not json".utf8)) == AccountInfo(billingModel: .metered))
    }

    @Test func accountRootsAndMissingFile() throws {
        let home = try makeTempDir()
        #expect(ClaudeAccountPlans.claudeJSON(for: "default", home: home) == home.appending(path: ".claude.json"))
        #expect(ClaudeAccountPlans.claudeJSON(for: "work", home: home) == home.appending(path: ".ccs/instances/work/.claude.json"))
        try writeClaudeJSON(#"{"oauthAccount":{"organizationType":"claude_team"}}"#, account: "work", home: home)
        var plans = ClaudeAccountPlans(home: home)
        #expect(plans.info(for: "work") == AccountInfo(billingModel: .subscription, plan: "team"))
        #expect(plans.info(for: "default") == AccountInfo(billingModel: .metered))
    }

    @Test func sessionReadsAnnotateDefaultAccountAndEstimatedCost() async throws {
        let home = try makeTempDir()
        try writeClaudeJSON(#"{"oauthAccount":{"organizationType":"claude_pro"}}"#, account: "default", home: home)
        let facade = ClaudeSwitchableProvider(
            jsonl: makeJSONLProvider(rootsEmptyDir: try makeTempDir()),
            hookProvider: ClaudeHookProvider(feedDir: try makeTempDir()),
            source: { .sessionReads },
            home: home
        )
        let snapshot = try await facade.fetch(now: Date())
        #expect(snapshot.accountInfo == AccountInfo(billingModel: .subscription, plan: "pro"))
        #expect(snapshot.costEstimated == (snapshot.costTodayUSD != nil))
    }


    @Test("hook mode gives each account its sessions' tokens; a session not in the feed stays unattributed (V9)")
    func hookAccountTokensBySession() async throws {
        let hookDir = try makeTempDir()
        let projects = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: hookDir)
            try? FileManager.default.removeItem(at: projects)
        }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))
        func line(_ request: String, _ input: Int) -> String {
            #"{"type":"assistant","timestamp":"\#(stamp)","requestId":"\#(request)","message":{"model":"claude-test","role":"assistant","usage":{"input_tokens":\#(input),"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        }
        func transcript(_ path: String, _ text: String) throws {
            let url = projects.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((text + "\n").utf8).write(to: url)
        }
        // One shared projects dir; only the feed's transcript_path names each session's account.
        try transcript("p/s1.jsonl", line("r1", 100))
        try transcript("p/s2/subagents/agent-a.jsonl", line("r2", 30))
        try transcript("p/s3.jsonl", line("r3", 7))
        try writeSession("s1", json: #"{ "session_id": "s1", "transcript_path": "/u/.ccs/instances/personal/projects/p/s1.jsonl", "cost": { "total_cost_usd": 1 } }"#,
                         mtime: now, in: hookDir)
        try writeSession("s2", json: #"{ "session_id": "s2", "transcript_path": "/u/.ccs/instances/work/projects/p/s2.jsonl", "cost": { "total_cost_usd": 2 } }"#,
                         mtime: now, in: hookDir)

        let facade = ClaudeSwitchableProvider(
            jsonl: makeJSONLProvider(rootsEmptyDir: projects),
            hookProvider: ClaudeHookProvider(feedDir: hookDir),
            source: { .hook }
        )
        let snap = try await facade.fetch(now: now)

        #expect(snap.tokensToday == 137)
        #expect(snap.accounts?.map(\.name) == ["personal", "work"])
        #expect(snap.accounts?.map(\.tokensToday) == [100, 30])
    }


    @Test("hook mode gives an account with no sessions a known 0, so a moved session leaves it (V9, B15)")
    func hookAccountWithoutSessionsIsZero() async throws {
        let hookDir = try makeTempDir()
        let projects = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: hookDir)
            try? FileManager.default.removeItem(at: projects)
        }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))
        let url = projects.appendingPathComponent("p/s1.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((#"{"type":"assistant","timestamp":"\#(stamp)","requestId":"r1","message":{"model":"claude-test","role":"assistant","usage":{"input_tokens":10,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n").utf8).write(to: url)
        try writeSession("s1", json: #"{ "session_id": "s1", "transcript_path": "/u/.ccs/instances/personal/projects/p/s1.jsonl", "cost": { "total_cost_usd": 1 } }"#,
                         mtime: now, in: hookDir)
        // work has a payload but no transcript of its own today.
        try writeSession("s9", json: #"{ "session_id": "s9", "transcript_path": "/u/.ccs/instances/work/projects/p/s9.jsonl", "cost": { "total_cost_usd": 0 } }"#,
                         mtime: now, in: hookDir)

        let facade = ClaudeSwitchableProvider(
            jsonl: makeJSONLProvider(rootsEmptyDir: projects),
            hookProvider: ClaudeHookProvider(feedDir: hookDir),
            source: { .hook }
        )
        let snap = try await facade.fetch(now: now)
        #expect(snap.accounts?.map(\.name) == ["personal", "work"])
        #expect(snap.accounts?.map(\.tokensToday) == [10, 0])
    }
}

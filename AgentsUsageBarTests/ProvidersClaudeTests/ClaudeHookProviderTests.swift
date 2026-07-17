import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("ClaudeHookProvider")
struct ClaudeHookProviderTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a session payload JSON file and stamps its modification date.
    @discardableResult
    private func writeSession(
        _ name: String,
        json: String,
        mtime: Date,
        in dir: URL
    ) throws -> URL {
        let url = dir.appendingPathComponent("\(name).json")
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    private func costJSON(sessionId: String, usd: Double) -> String {
        """
        { "session_id": "\(sessionId)", "cost": { "total_cost_usd": \(usd) } }
        """
    }

    private func quotaJSON(sessionId: String, fivePct: Double, sevenPct: Double, resetsAt: Double) -> String {
        """
        {
          "session_id": "\(sessionId)",
          "cost": { "total_cost_usd": 0.0 },
          "rate_limits": {
            "five_hour": { "used_percentage": \(fivePct), "resets_at": \(resetsAt) },
            "seven_day": { "used_percentage": \(sevenPct), "resets_at": \(resetsAt) }
          }
        }
        """
    }

    // MARK: - Cost

    @Test func sumsTodayCostAcrossSessions() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let today = TodayHelper.startOfDay(now, calendar: .current)
        // Two sessions modified today (a bit after midnight, and now).
        try writeSession("a", json: costJSON(sessionId: "a", usd: 1.0),
                         mtime: today.addingTimeInterval(60), in: dir)
        try writeSession("b", json: costJSON(sessionId: "b", usd: 2.5),
                         mtime: now, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        #expect(snap.costTodayUSD == Decimal(string: "3.5"))
        #expect(snap.tokensToday == nil)
        #expect(snap.providerID == .claude)
    }

    @Test func excludesYesterdayMtimeFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let today = TodayHelper.startOfDay(now, calendar: .current)
        // Yesterday: one hour before local midnight (still within the 24h staleness window).
        let yesterday = today.addingTimeInterval(-3600)

        try writeSession("today", json: costJSON(sessionId: "today", usd: 4.0),
                         mtime: now, in: dir)
        try writeSession("yday", json: costJSON(sessionId: "yday", usd: 99.0),
                         mtime: yesterday, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        // Only today's 4.0 counts; yesterday's 99.0 excluded.
        #expect(snap.costTodayUSD == Decimal(string: "4.0"))
    }

    // MARK: - Quota

    @Test func picksQuotaFromNewestPayload() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let reset = now.addingTimeInterval(3600).timeIntervalSince1970

        // Older payload: high utilization.
        try writeSession("old", json: quotaJSON(sessionId: "old", fivePct: 90, sevenPct: 90, resetsAt: reset),
                         mtime: now.addingTimeInterval(-600), in: dir)
        // Newer payload: 40% five-hour, 10% seven-day → should win.
        try writeSession("new", json: quotaJSON(sessionId: "new", fivePct: 40, sevenPct: 10, resetsAt: reset),
                         mtime: now, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        let windows = try #require(snap.quotaWindows)
        let five = try #require(windows.first { $0.name == "5h" })
        let seven = try #require(windows.first { $0.name == "7d" })
        #expect(five.utilization == 0.4)
        #expect(seven.utilization == 0.1)
        #expect(five.resetsAt == Date(timeIntervalSince1970: reset))

        // Primary quota = max(5h, 7d) fraction = 0.4.
        let quota = try #require(snap.quota)
        #expect(quota.used == 0.4)
        #expect(quota.limit == 1.0)
    }

    // MARK: - Empty / stale

    @Test func emptyDirThrows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = ClaudeHookProvider(feedDir: dir)
        await #expect(throws: ClaudeHookError.noFeedData) {
            _ = try await provider.fetch(now: Date())
        }
    }

    @Test func missingDirThrows() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Deliberately not created.
        let provider = ClaudeHookProvider(feedDir: dir)
        await #expect(throws: ClaudeHookError.noFeedData) {
            _ = try await provider.fetch(now: Date())
        }
    }

    @Test func staleNewestFileYieldsZeroSnapshot() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        // Newest file is 25h old → the user simply hasn't used Claude Code lately.
        // That is a legitimate zero-usage state, NOT a broken hook: zero snapshot,
        // no quota (stale rate limits would mislead), no error row.
        try writeSession("stale", json: costJSON(sessionId: "stale", usd: 5.0),
                         mtime: now.addingTimeInterval(-25 * 3600), in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)
        #expect(snap.costTodayUSD == 0)
        #expect(snap.tokensToday == nil)
        #expect(snap.quota == nil)
        #expect(snap.quotaWindows == nil)
        #expect(await provider.status() == .ok(lastSuccess: now))
    }

    // MARK: - Multi-account (DESIGN-hook-multi-account)

    /// Legacy flat file ("default") + sessions/personal/ subdir → merged cost, per-account
    /// raw keys, account-prefixed window names, primary quota = max across accounts,
    /// tooltip breakdown line.
    @Test func multiAccount_mergesCostAndSplitsQuotaPerAccount() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let resets = now.addingTimeInterval(3600).timeIntervalSince1970

        // Legacy flat file → account "default": $1.00 today, 40%/10% windows.
        try writeSession("d1", json: """
        {
          "session_id": "d1",
          "cost": { "total_cost_usd": 1.0 },
          "rate_limits": {
            "five_hour": { "used_percentage": 40, "resets_at": \(resets) },
            "seven_day": { "used_percentage": 10, "resets_at": \(resets) }
          }
        }
        """, mtime: now, in: dir)

        // Instance subdir → account "personal": $0.25 today, 70% seven-day window.
        let personalDir = dir.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: personalDir, withIntermediateDirectories: true)
        try writeSession("p1", json: """
        {
          "session_id": "p1",
          "cost": { "total_cost_usd": 0.25 },
          "rate_limits": {
            "seven_day": { "used_percentage": 70, "resets_at": \(resets) }
          }
        }
        """, mtime: now, in: personalDir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        // Merged cost across accounts.
        #expect(snap.costTodayUSD == Decimal(string: "1.25"))

        // Account-prefixed window names, default first.
        let names = try #require(snap.quotaWindows).map(\.name)
        #expect(names == ["default 5h", "default 7d", "personal 7d"])

        // Primary quota = max across ALL accounts (personal's 70% wins).
        let quota = try #require(snap.quota)
        #expect(quota.used == 0.7)

        // Per-account raw keys for the popover breakdown.
        #expect(snap.raw["cost.default"] == "1")
        #expect(snap.raw["cost.personal"] == "0.25")
        #expect(snap.raw["quota.default"] == "40%")
        #expect(snap.raw["quota.personal"] == "70%")

        // Tooltip breakdown, default first.
        #expect(snap.tooltipLabel == "default $1.00 40% · personal $0.25 70%")

        // Per-account slices for the row's indented children.
        let accountRows = try #require(snap.accounts)
        #expect(accountRows.map(\.name) == ["default", "personal"])
        #expect(accountRows[0].costTodayUSD == Decimal(string: "1"))
        #expect(accountRows[0].quota?.used == 0.4)
        #expect(accountRows[0].quotaWindows?.map(\.name) == ["5h", "7d"])
        #expect(accountRows[1].costTodayUSD == Decimal(string: "0.25"))
        #expect(accountRows[1].quota?.used == 0.7)
        #expect(accountRows[1].quotaWindows?.map(\.name) == ["7d"])
    }

    /// The same session captured under several account dirs (runtime env flapping in
    /// shared-settings ccs setups) must count its cumulative cost ONCE — newest copy wins,
    /// and it also decides the session's account attribution.
    @Test func duplicateSessionAcrossAccounts_newestCopyWins() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        // Older copy under legacy flat "default" says $9.00…
        try writeSession("dup", json: costJSON(sessionId: "dup", usd: 9.0),
                         mtime: now.addingTimeInterval(-600), in: dir)
        // …newer copy under personal/ says $2.00 (fresher cumulative figure).
        let personalDir = dir.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: personalDir, withIntermediateDirectories: true)
        try writeSession("dup", json: costJSON(sessionId: "dup", usd: 2.0),
                         mtime: now, in: personalDir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        // Counted once, from the newest copy, attributed to "personal" — and with a
        // single surviving account there is no multi-account breakdown.
        #expect(snap.costTodayUSD == Decimal(string: "2"))
        #expect(snap.raw["cost.personal"] == "2")
        #expect(snap.raw["cost.default"] == nil)
        #expect(snap.tooltipLabel == nil)
    }

    /// transcript_path beats the feed directory for account attribution: the runtime
    /// $CLAUDE_CONFIG_DIR routing flaps in shared-settings ccs setups, so a personal
    /// session can be captured under work/. The payload's transcript_path is the truth.
    @Test func transcriptPathOverridesDirectoryAttribution() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        // Captured under work/ — but the payload belongs to the personal instance.
        let workDir = dir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try writeSession("s1", json: """
        {
          "session_id": "s1",
          "transcript_path": "/Users/x/.ccs/instances/personal/projects/p/s1.jsonl",
          "cost": { "total_cost_usd": 4.0 }
        }
        """, mtime: now, in: workDir)
        // A default-account session, flat legacy layout, no transcript_path → dir fallback.
        try writeSession("s2", json: costJSON(sessionId: "s2", usd: 1.0), mtime: now, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        #expect(snap.raw["cost.personal"] == "4")
        #expect(snap.raw["cost.work"] == nil)
        #expect(snap.raw["cost.default"] == "1")
        #expect(snap.accounts?.map(\.name) == ["default", "personal"])
    }

    /// Path→account mapping used for attribution.
    @Test func accountFromTranscriptPath() {
        #expect(ClaudeHookProvider.account(
            fromTranscriptPath: "/Users/x/.ccs/instances/work/projects/p/s.jsonl") == "work")
        #expect(ClaudeHookProvider.account(
            fromTranscriptPath: "/Users/x/.claude/projects/p/s.jsonl") == "default")
        #expect(ClaudeHookProvider.account(
            fromTranscriptPath: "/Users/x/.ccs/shared/context-groups/g/projects/p/s.jsonl") == nil)
        #expect(ClaudeHookProvider.account(fromTranscriptPath: nil) == nil)
    }

    /// Single-account feeds keep the plain "5h"/"7d" names and nil tooltip — a9d9353
    /// regression guard.
    @Test func singleAccount_keepsPlainWindowNamesAndNilTooltip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let resets = now.addingTimeInterval(3600).timeIntervalSince1970
        try writeSession("s", json: quotaJSON(sessionId: "s", fivePct: 23.5, sevenPct: 41.2, resetsAt: resets),
                         mtime: now, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        #expect(try #require(snap.quotaWindows).map(\.name) == ["5h", "7d"])
        #expect(snap.tooltipLabel == nil)
        // accounts is still populated (one slice) — the UI hides children below 2.
        #expect(snap.accounts?.count == 1)
        #expect(snap.accounts?.first?.name == "default")
    }

    /// Cleanup + pruneFeed reach account subdirectories.
    @Test func pruneFeedCoversAccountSubdirs() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let personalDir = dir.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: personalDir, withIntermediateDirectories: true)
        let old = try writeSession("old", json: costJSON(sessionId: "old", usd: 1.0),
                                   mtime: now.addingTimeInterval(-49 * 3600), in: personalDir)
        let fresh = try writeSession("fresh", json: costJSON(sessionId: "fresh", usd: 1.0),
                                     mtime: now, in: personalDir)

        let provider = ClaudeHookProvider(feedDir: dir)
        await provider.pruneFeed(now: now)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func pruneFeedRemovesOldFilesWithoutFetching() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let old = try writeSession("old", json: costJSON(sessionId: "old", usd: 1.0),
                                   mtime: now.addingTimeInterval(-49 * 3600), in: dir)
        let fresh = try writeSession("fresh", json: costJSON(sessionId: "fresh", usd: 1.0),
                                     mtime: now, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        await provider.pruneFeed(now: now)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    // MARK: - Cleanup

    @Test func deletesFilesOlderThan48h() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let fresh = try writeSession("fresh", json: costJSON(sessionId: "fresh", usd: 1.0),
                                     mtime: now, in: dir)
        let old = try writeSession("old", json: costJSON(sessionId: "old", usd: 2.0),
                                   mtime: now.addingTimeInterval(-49 * 3600), in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        _ = try await provider.fetch(now: now)

        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
}

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

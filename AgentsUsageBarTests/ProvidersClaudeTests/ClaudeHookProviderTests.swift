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

    /// Live bug 2026-09-09: a work session hit 5h 100% and stopped writing (rate-limited).
    /// A later still-running session dumped 86% for the SAME `resets_at`. Newest-mtime
    /// overwrote the peak, so the popover bar was red but not full.
    @Test func sameWindowKeepsPeakUtilization() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let reset = now.addingTimeInterval(3600).timeIntervalSince1970

        try writeSession("hit-limit", json: quotaJSON(sessionId: "hit-limit", fivePct: 100, sevenPct: 66, resetsAt: reset),
                         mtime: now.addingTimeInterval(-600), in: dir)
        try writeSession("later", json: quotaJSON(sessionId: "later", fivePct: 86, sevenPct: 64, resetsAt: reset),
                         mtime: now, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        let windows = try #require(snap.quotaWindows)
        let five = try #require(windows.first { $0.name == "5h" })
        let seven = try #require(windows.first { $0.name == "7d" })
        #expect(five.utilization == 1.0)
        #expect(seven.utilization == 0.66)
        #expect(five.resetsAt == Date(timeIntervalSince1970: reset))

        let quota = try #require(snap.quota)
        #expect(quota.used == 1.0)
        #expect(quota.remaining == 0)
    }

    @Test func newWindowReplacesPreviousUtilization() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let oldReset = now.addingTimeInterval(-60).timeIntervalSince1970
        let newReset = now.addingTimeInterval(3600).timeIntervalSince1970

        try writeSession("old-window", json: quotaJSON(sessionId: "old-window", fivePct: 100, sevenPct: 90, resetsAt: oldReset),
                         mtime: now.addingTimeInterval(-600), in: dir)
        try writeSession("new-window", json: quotaJSON(sessionId: "new-window", fivePct: 40, sevenPct: 10, resetsAt: newReset),
                         mtime: now, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        let windows = try #require(snap.quotaWindows)
        let five = try #require(windows.first { $0.name == "5h" })
        let seven = try #require(windows.first { $0.name == "7d" })
        #expect(five.utilization == 0.4)
        #expect(seven.utilization == 0.1)
        #expect(five.resetsAt == Date(timeIntervalSince1970: newReset))

        let quota = try #require(snap.quota)
        #expect(quota.used == 0.4)
        #expect(quota.limit == 1.0)
    }

    /// Newest payload can omit `five_hour` (observed on idle / post-reset dumps).
    /// That must not wipe a same-window peak captured by an older session.
    @Test func newerPayloadMissingFiveHourPreservesPeak() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let reset = now.addingTimeInterval(3600).timeIntervalSince1970

        try writeSession("with-5h", json: quotaJSON(sessionId: "with-5h", fivePct: 90, sevenPct: 20, resetsAt: reset),
                         mtime: now.addingTimeInterval(-600), in: dir)
        try writeSession("seven-only", json: """
        {
          "session_id": "seven-only",
          "cost": { "total_cost_usd": 0.0 },
          "rate_limits": {
            "seven_day": { "used_percentage": 22, "resets_at": \(reset) }
          }
        }
        """, mtime: now, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        let windows = try #require(snap.quotaWindows)
        let five = try #require(windows.first { $0.name == "5h" })
        let seven = try #require(windows.first { $0.name == "7d" })
        #expect(five.utilization == 0.9)
        #expect(seven.utilization == 0.22)
        #expect(try #require(snap.quota).used == 0.9)
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
        // Newest file is 25h old with no rate limits → zero cost, no quota data to keep.
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

    /// Stale feed (>24h) with a future 7d reset → the window is kept with last-known
    /// utilization. This is the #73 scenario: a limit-reached account can't run sessions,
    /// so the feed goes stale exactly when the reset countdown matters most.
    @Test func staleFeedKeepsUnexpiredQuotaWindows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        // 25h old file — stale feed.
        let staleMtime = now.addingTimeInterval(-25 * 3600)
        // 5h window resets 24h ago (expired) — should be dropped.
        let expired5hReset = now.addingTimeInterval(-24 * 3600).timeIntervalSince1970
        // 7d window resets in 10h (future) — should be kept.
        let future7dReset = now.addingTimeInterval(10 * 3600).timeIntervalSince1970
        try writeSession("stale", json: """
        {
          "session_id": "stale",
          "cost": { "total_cost_usd": 0.0 },
          "rate_limits": {
            "five_hour": { "used_percentage": 99, "resets_at": \(expired5hReset) },
            "seven_day": { "used_percentage": 99, "resets_at": \(future7dReset) }
          }
        }
        """, mtime: staleMtime, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        // Cost is 0 for stale feeds.
        #expect(snap.costTodayUSD == 0)
        // 5h window expired — dropped.
        let windows = try #require(snap.quotaWindows)
        #expect(windows.map(\.name) == ["7d"])
        let seven = try #require(windows.first { $0.name == "7d" })
        #expect(seven.utilization == 0.99)
        #expect(seven.resetsAt == Date(timeIntervalSince1970: future7dReset))
        // Primary quota follows the kept window.
        let quota = try #require(snap.quota)
        #expect(quota.used == 0.99)
    }

    /// Stale feed with ALL windows already expired → no quota returned.
    @Test func staleFeedDropsAllExpiredQuotaWindows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let staleMtime = now.addingTimeInterval(-25 * 3600)
        // Both windows expired.
        let old5hReset = now.addingTimeInterval(-24 * 3600).timeIntervalSince1970
        let old7dReset = now.addingTimeInterval(-10 * 3600).timeIntervalSince1970
        try writeSession("stale", json: """
        {
          "session_id": "stale",
          "cost": { "total_cost_usd": 0.0 },
          "rate_limits": {
            "five_hour": { "used_percentage": 99, "resets_at": \(old5hReset) },
            "seven_day": { "used_percentage": 99, "resets_at": \(old7dReset) }
          }
        }
        """, mtime: staleMtime, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        #expect(snap.costTodayUSD == 0)
        #expect(snap.quota == nil)
        #expect(snap.quotaWindows == nil)
    }

    /// Stale multi-account feed: only the unexpired windows per account are kept.
    @Test func staleMultiAccountFeedKeepsUnexpiredWindowsPerAccount() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let staleMtime = now.addingTimeInterval(-25 * 3600)

        // "personal" account: 7d resets in 10h (keep), 5h expired (drop).
        let personalDir = dir.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: personalDir, withIntermediateDirectories: true)
        let expired5hReset = now.addingTimeInterval(-24 * 3600).timeIntervalSince1970
        let future7dReset = now.addingTimeInterval(10 * 3600).timeIntervalSince1970
        try writeSession("p1", json: """
        {
          "session_id": "p1",
          "cost": { "total_cost_usd": 0.0 },
          "rate_limits": {
            "five_hour": { "used_percentage": 99, "resets_at": \(expired5hReset) },
            "seven_day": { "used_percentage": 75, "resets_at": \(future7dReset) }
          }
        }
        """, mtime: staleMtime, in: personalDir)

        // "work" account: both windows expired.
        let workDir = dir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let old5hReset = now.addingTimeInterval(-6 * 3600).timeIntervalSince1970
        let old7dReset = now.addingTimeInterval(-10 * 3600).timeIntervalSince1970
        try writeSession("w1", json: """
        {
          "session_id": "w1",
          "cost": { "total_cost_usd": 0.0 },
          "rate_limits": {
            "five_hour": { "used_percentage": 50, "resets_at": \(old5hReset) },
            "seven_day": { "used_percentage": 80, "resets_at": \(old7dReset) }
          }
        }
        """, mtime: staleMtime, in: workDir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        #expect(snap.costTodayUSD == 0)
        // Only personal 7d survives.
        let windows = try #require(snap.quotaWindows)
        #expect(windows.map(\.name) == ["personal 7d"])
        let quota = try #require(snap.quota)
        #expect(quota.used == 0.75)

        // Per-account slices.
        let accounts = try #require(snap.accounts)
        #expect(accounts.map(\.name) == ["personal", "work"])
        #expect(accounts[0].quota?.used == 0.75)
        #expect(accounts[1].quota == nil)
    }

    // MARK: - Cleanup retention (#73)

    /// A session file older than the 48h cleanup horizon whose 7d window still has a
    /// future reset must survive cleanup, on every fetch, until the window expires.
    @Test func cleanupRetainsNewestFileWithUnexpiredWindowAcrossFetches() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let t0 = Date()
        // File is 50h old — past the 48h cleanup horizon. 7d window resets in 3 days.
        let fileMtime = t0.addingTimeInterval(-50 * 3600)
        let future7dReset = t0.addingTimeInterval(3 * 86400).timeIntervalSince1970
        try writeSession("slow", json: """
        {
          "session_id": "slow",
          "cost": { "total_cost_usd": 0.0 },
          "rate_limits": {
            "five_hour": { "used_percentage": 99, "resets_at": \(t0.addingTimeInterval(-2 * 86400).timeIntervalSince1970) },
            "seven_day": { "used_percentage": 99, "resets_at": \(future7dReset) }
          }
        }
        """, mtime: fileMtime, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)

        // Fetch #1 at t0: file is past the horizon but the 7d window is kept.
        let snap1 = try await provider.fetch(now: t0)
        #expect(try #require(snap1.quotaWindows).map(\.name) == ["7d"])

        // Fetch #2 twelve hours later: the file is now 62h old — it must still survive.
        let t1 = t0.addingTimeInterval(12 * 3600)
        let snap2 = try await provider.fetch(now: t1)
        #expect(try #require(snap2.quotaWindows).map(\.name) == ["7d"])
        #expect(try #require(snap2.quota).used == 0.99)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("slow.json").path))
    }

    /// A session file older than the horizon with ONLY expired windows is still deleted —
    /// retention must not turn the feed into a permanent archive.
    @Test func cleanupStillDeletesFileWithOnlyExpiredWindows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let fileMtime = now.addingTimeInterval(-50 * 3600)
        let old5hReset = now.addingTimeInterval(-24 * 3600).timeIntervalSince1970
        let old7dReset = now.addingTimeInterval(-10 * 3600).timeIntervalSince1970
        let url = try writeSession("expired", json: """
        {
          "session_id": "expired",
          "cost": { "total_cost_usd": 0.0 },
          "rate_limits": {
            "five_hour": { "used_percentage": 99, "resets_at": \(old5hReset) },
            "seven_day": { "used_percentage": 50, "resets_at": \(old7dReset) }
          }
        }
        """, mtime: fileMtime, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)
        #expect(snap.quota == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Superseded copies (same session name, older mtime) are deleted even when they
    /// carry an unexpired window — only the newest copy is retained.
    @Test func cleanupDeletesSupersededCopiesWithUnexpiredWindows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let futureReset = now.addingTimeInterval(2 * 86400).timeIntervalSince1970
        let json = quotaJSON(sessionId: "s1", fivePct: 99, sevenPct: 50, resetsAt: futureReset)

        // Flat "default" copy: 60h old. Subdir copy (account "work"): 52h old → newest.
        let flat = try writeSession("s1", json: json, mtime: now.addingTimeInterval(-60 * 3600), in: dir)
        let workDir = dir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let newest = try writeSession("s1", json: json, mtime: now.addingTimeInterval(-52 * 3600), in: workDir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)
        #expect(try #require(snap.quota).used == 0.99)
        #expect(!FileManager.default.fileExists(atPath: flat.path))
        #expect(FileManager.default.fileExists(atPath: newest.path))
    }

    /// The public prune path (sessionReads mode) honors the same retention rule.
    @Test func pruneFeedRetainsUnexpiredWindowFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let fileMtime = now.addingTimeInterval(-50 * 3600)
        let futureReset = now.addingTimeInterval(2 * 86400).timeIntervalSince1970
        let url = try writeSession("keepme", json: quotaJSON(sessionId: "keepme", fivePct: 99, sevenPct: 50, resetsAt: futureReset),
                                   mtime: fileMtime, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        await provider.pruneFeed(now: now)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Stale idle account next to a fresh one (astra review, PR #74)

    /// A retained idle account (40h old, 7d window still live) sits next to a fresh
    /// active account. The fresh file keeps the feed non-stale, but the idle
    /// account's EXPIRED 100% 5h window must not resurrect into the displayed
    /// windows or drive the primary quota — only its unexpired 7d window counts.
    @Test func staleIdleAccountKeepsOnlyUnexpiredWindowNextToActiveAccount() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()

        // Active account: fresh file (1 minute), both windows live.
        let activeDir = dir.appendingPathComponent("active", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
        let activeJson = """
        {
          "session_id": "active-1",
          "cost": { "total_cost_usd": 0.5 },
          "rate_limits": {
            "five_hour": { "used_percentage": 20, "resets_at": \(now.addingTimeInterval(3600).timeIntervalSince1970) },
            "seven_day": { "used_percentage": 10, "resets_at": \(now.addingTimeInterval(24 * 3600).timeIntervalSince1970) }
          }
        }
        """
        _ = try writeSession("active-1", json: activeJson, mtime: now.addingTimeInterval(-60), in: activeDir)

        // Retained idle account: 40h old; 5h window expired 39h ago, 7d window
        // resets in 30h (which is why the 48h cleanup retains the file).
        let idleDir = dir.appendingPathComponent("idle", isDirectory: true)
        try FileManager.default.createDirectory(at: idleDir, withIntermediateDirectories: true)
        let idleJson = """
        {
          "session_id": "idle-1",
          "cost": { "total_cost_usd": 0.0 },
          "rate_limits": {
            "five_hour": { "used_percentage": 100, "resets_at": \(now.addingTimeInterval(-39 * 3600).timeIntervalSince1970) },
            "seven_day": { "used_percentage": 30, "resets_at": \(now.addingTimeInterval(30 * 3600).timeIntervalSince1970) }
          }
        }
        """
        _ = try writeSession("idle-1", json: idleJson, mtime: now.addingTimeInterval(-40 * 3600), in: idleDir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        let windowNames = try #require(snap.quotaWindows).map(\.name)
        // The retained 7d window of the idle account is still reported.
        #expect(windowNames.contains("idle 7d"))
        // The idle account's expired 5h window does not resurrect.
        #expect(!windowNames.contains("idle 5h"))
        // Primary quota = max of live windows (20, 10, 30), NOT the dead 100% 5h.
        #expect(try #require(snap.quota).used == 0.3)
    }

    // MARK: - Per-slot window freshness (astra P2 re-review, PR #74)

    /// Core #73 regression: a single-account file older than the 48h retention
    /// horizon (retained because its windows are unexpired) still reports its
    /// unexpired 5h countdown — the limit-reached case the retention rule exists for.
    @Test func staleFeedKeepsUnexpiredFiveHourWindow() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        // 5 days old — past the 48h retention horizon; retained via unexpired windows.
        let staleMtime = now.addingTimeInterval(-5 * 24 * 3600)
        let live5hReset = now.addingTimeInterval(5 * 3600).timeIntervalSince1970
        let live7dReset = now.addingTimeInterval(30 * 3600).timeIntervalSince1970
        try writeSession("default", json: """
        {
          "session_id": "default",
          "cost": { "total_cost_usd": 0.0 },
          "rate_limits": {
            "five_hour": { "used_percentage": 60, "resets_at": \(live5hReset) },
            "seven_day": { "used_percentage": 20, "resets_at": \(live7dReset) }
          }
        }
        """, mtime: staleMtime, in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        #expect(snap.costTodayUSD == 0)
        let windows = try #require(snap.quotaWindows)
        #expect(windows.map(\.name) == ["5h", "7d"])
        let five = try #require(windows.first { $0.name == "5h" })
        #expect(five.utilization == 0.6)
        #expect(try #require(snap.quota).used == 0.6)
    }

    /// Guard: the same payload shape from a fresh file keeps both windows as before.
    @Test func freshFeedKeepsAllWindowsFromRecentPayload() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let live5hReset = now.addingTimeInterval(5 * 3600).timeIntervalSince1970
        let live7dReset = now.addingTimeInterval(30 * 3600).timeIntervalSince1970
        try writeSession("default", json: """
        {
          "session_id": "default",
          "cost": { "total_cost_usd": 0.0 },
          "rate_limits": {
            "five_hour": { "used_percentage": 60, "resets_at": \(live5hReset) },
            "seven_day": { "used_percentage": 20, "resets_at": \(live7dReset) }
          }
        }
        """, mtime: now.addingTimeInterval(-60), in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        let windows = try #require(snap.quotaWindows)
        #expect(windows.map(\.name) == ["5h", "7d"])
        #expect(try #require(snap.quota).used == 0.6)
    }

    /// P2 regression: within ONE account, a stale session's EXPIRED 5h window must
    /// be dropped even though a fresh sibling session in the same account keeps the
    /// feed (and account) non-stale. Under per-feed/per-account freshness the
    /// expired 100% window would resurrect and drive the primary quota; per-slot
    /// freshness drops it, so only the fresh session's 7d window counts.
    @Test func staleSessionExpiredFiveHourWindowDroppedDespiteFreshSiblingSession() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        // Old session (5 days): expired 100% 5h window, no 7d.
        let expired5hReset = now.addingTimeInterval(-4 * 24 * 3600).timeIntervalSince1970
        try writeSession("old", json: """
        {
          "session_id": "old",
          "cost": { "total_cost_usd": 0.0 },
          "rate_limits": {
            "five_hour": { "used_percentage": 100, "resets_at": \(expired5hReset) }
          }
        }
        """, mtime: now.addingTimeInterval(-5 * 24 * 3600), in: dir)

        // Fresh session (1 minute): live 7d window, no 5h.
        let live7dReset = now.addingTimeInterval(30 * 3600).timeIntervalSince1970
        try writeSession("new", json: """
        {
          "session_id": "new",
          "cost": { "total_cost_usd": 0.0 },
          "rate_limits": {
            "seven_day": { "used_percentage": 10, "resets_at": \(live7dReset) }
          }
        }
        """, mtime: now.addingTimeInterval(-60), in: dir)

        let provider = ClaudeHookProvider(feedDir: dir)
        let snap = try await provider.fetch(now: now)

        // The expired 5h window from the stale session must not resurrect:
        // only the fresh session's 7d window is visible.
        let windows = try #require(snap.quotaWindows)
        #expect(windows.map(\.name) == ["7d"])
        #expect(try #require(snap.quota).used == 0.1)
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


    @Test("sessionAccounts: transcript_path wins, directory without it, unreadable payloads skipped, newest copy (V9)")
    func sessionAccountsAttribution() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work", isDirectory: true)
        let personal = dir.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        let now = Date()
        // Captured under work/, but the transcript names personal.
        try writeSession("s1", json: #"{ "session_id": "s1", "transcript_path": "/u/.ccs/instances/personal/projects/p/s1.jsonl" }"#,
                         mtime: now, in: work)
        // No transcript_path: the directory names the account.
        try writeSession("s2", json: #"{ "session_id": "s2" }"#, mtime: now, in: work)
        // Unreadable: skipped, as fetch skips it.
        try writeSession("s3", json: "{ not json", mtime: now, in: personal)
        // Two copies: the newer one wins.
        try writeSession("s4", json: #"{ "session_id": "s4" }"#, mtime: now.addingTimeInterval(-60), in: work)
        try writeSession("s4", json: #"{ "session_id": "s4" }"#, mtime: now, in: personal)

        #expect(ClaudeHookProvider.sessionAccounts(feedDir: dir) == ["s1": "personal", "s2": "work", "s4": "personal"])
        #expect(ClaudeHookProvider.sessionAccounts(feedDir: dir.appendingPathComponent("missing")).isEmpty)
    }
}

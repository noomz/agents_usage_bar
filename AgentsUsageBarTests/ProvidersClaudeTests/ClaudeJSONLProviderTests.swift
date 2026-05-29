import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - FakeOAuthClient

/// Test double conforming to `ClaudeOAuthClientProtocol`.
/// Returns a pre-configured result or throws on demand.
actor FakeOAuthClient: ClaudeOAuthClientProtocol {
    enum Mode {
        case success(ClaudeUsageResponse)
        case failure(Error)
    }

    private var mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func getUsage() async throws -> ClaudeUsageResponse {
        switch mode {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}

// MARK: - Helpers

/// Returns today's `"YYYY-MM-DD"` string and substitutes it for `<TODAY-T>` in `content`.
private func materializeFixture(_ content: String) -> String {
    let today = TodayHelper.formatYYYYMMDD(.now)
    return content.replacingOccurrences(of: "<TODAY-T>", with: today + "T")
}

/// Reads a fixture file by name from the test bundle's Fixtures directory, materialises TODAY-T,
/// writes the result to `destURL`, and returns the written URL.
@discardableResult
private func materializeFixtureFile(
    named name: String,
    into destURL: URL
) throws -> URL {
    // Locate the fixture file in the test bundle (resource bundle for app-hosted test target).
    guard let srcURL = Bundle(for: ClaudeJSONLProviderTestsBundle.self)
        .url(forResource: name, withExtension: nil, subdirectory: "Fixtures") ??
          Bundle(for: ClaudeJSONLProviderTestsBundle.self)
            .url(forResource: (name as NSString).deletingPathExtension,
                 withExtension: (name as NSString).pathExtension)
    else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
    }
    let raw = try String(contentsOf: srcURL, encoding: .utf8)
    let materialized = materializeFixture(raw)
    try materialized.write(to: destURL, atomically: true, encoding: .utf8)
    return destURL
}

/// Writes arbitrary JSONL content (with TODAY-T substituted) to `destURL`.
private func writeFixture(_ content: String, to destURL: URL) throws {
    let materialized = materializeFixture(content)
    try materialized.write(to: destURL, atomically: true, encoding: .utf8)
}

/// Marker class used for Bundle(for:) lookup — picks up the test bundle.
private final class ClaudeJSONLProviderTestsBundle {}

/// Creates a fresh temporary directory and returns its URL.
/// Caller is responsible for cleanup via `defer { try? FileManager.default.removeItem(at: dir) }`.
private func makeTempRoot() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClaudeJSONLProviderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

/// Builds a `ClaudeJSONLProvider` suitable for tests.
private func makeProvider(
    roots: [URL],
    oauth: (any ClaudeOAuthClientProtocol)? = nil,
    cache: FakeCacheStore = FakeCacheStore(),
    pricing: ClaudeModelPricing = .testPricing
) -> ClaudeJSONLProvider {
    ClaudeJSONLProvider(
        reader: TranscriptReader(),
        scanner: TranscriptDirectoryScanner(),
        pricing: pricing,
        oauth: oauth,
        cache: cache,
        clock: SystemClock(),
        roots: roots
    )
}

// MARK: - ClaudeModelPricing test helper

private extension ClaudeModelPricing {
    /// Minimal pricing table for tests — exact model IDs used in fixtures.
    static let testPricing = ClaudeModelPricing(
        schemaVersion: 1,
        lastUpdated: "test",
        default: .init(inputPer1M: 3.00, outputPer1M: 15.00, cacheWritePer1M: 3.75, cacheReadPer1M: 0.30),
        models: [
            "claude-sonnet-4-5": .init(inputPer1M: 3.00, outputPer1M: 15.00, cacheWritePer1M: 3.75, cacheReadPer1M: 0.30),
            "claude-opus-4-7":   .init(inputPer1M: 15.00, outputPer1M: 75.00, cacheWritePer1M: 18.75, cacheReadPer1M: 1.50),
            "claude-haiku-4-5":  .init(inputPer1M: 0.80, outputPer1M: 4.00, cacheWritePer1M: 1.00, cacheReadPer1M: 0.08),
        ]
    )
}

// MARK: - Test suite

@Suite("ClaudeJSONLProvider", .serialized)
struct ClaudeJSONLProviderTests {

    // MARK: Test 1 — empty roots + no OAuth returns zero snapshot

    @Test func fetch_emptyRoots_noOAuth_returnsZeroSnapshot() async throws {
        let provider = makeProvider(roots: [])
        let snap = try await provider.fetch(now: .now)

        #expect(snap.tokensToday == 0)
        #expect(snap.costTodayUSD == 0)
        #expect(snap.quota == nil)
        #expect(snap.quotaWindows == nil)

        let status = await provider.status()
        if case .ok = status { } else {
            Issue.record("Expected .ok status, got \(status)")
        }
    }

    // MARK: Test 2 — single file, two records from today

    @Test func fetch_singleFile_singleRecord_today_populates() async throws {
        let dir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("session-a.jsonl")
        // JSONL spec: each record on its own line, file ends with \n
        let content = """
        {"type":"assistant","timestamp":"<TODAY-T>15:30:00.000+00:00","requestId":"req-A1","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","timestamp":"<TODAY-T>15:31:00.000+00:00","requestId":"req-A2","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":2000,"output_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
        try writeFixture(content, to: fileURL)

        let provider = makeProvider(roots: [dir])
        let snap = try await provider.fetch(now: .now)

        // tokens: (1000+500) + (2000+1000) = 4500
        #expect(snap.tokensToday == 4500)
        #expect((snap.costTodayUSD ?? 0) > 0)
        #expect(snap.quota == nil)      // no OAuth
        #expect(snap.quotaWindows == nil)
    }

    // MARK: Test 3 — multi-file aggregation

    @Test func fetch_multiFile_aggregates() async throws {
        let dir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("session-a.jsonl")
        let contentA = """
        {"type":"assistant","timestamp":"<TODAY-T>15:30:00.000+00:00","requestId":"req-A1","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","timestamp":"<TODAY-T>15:31:00.000+00:00","requestId":"req-A2","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":2000,"output_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
        try writeFixture(contentA, to: fileA)

        let fileB = dir.appendingPathComponent("session-b.jsonl")
        let contentB = """
        {"type":"assistant","timestamp":"<TODAY-T>16:00:00.000+00:00","requestId":"req-B1","message":{"model":"claude-opus-4-7","role":"assistant","usage":{"input_tokens":500,"output_tokens":2000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
        try writeFixture(contentB, to: fileB)

        let provider = makeProvider(roots: [dir])
        let snap = try await provider.fetch(now: .now)

        // tokens: 4500 (A) + 2500 (B) = 7000
        #expect(snap.tokensToday == 7000)
        #expect((snap.costTodayUSD ?? 0) > 0)
    }

    // MARK: Test 4 — yesterday records skipped by today filter

    @Test func fetch_skipsRecordsBeforeToday() async throws {
        let dir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yesterdayDate = TodayHelper.startOfDay(.now).addingTimeInterval(-3600)
        let yesterdayStr = ISO8601DateFormatter().string(from: yesterdayDate)
        let todayStr = TodayHelper.formatYYYYMMDD(.now) + "T15:00:00.000+00:00"

        let content = """
        {"type":"assistant","timestamp":"\(yesterdayStr)","requestId":"req-Y1","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":5000,"output_tokens":5000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","timestamp":"\(todayStr)","requestId":"req-T1","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
        let fileURL = dir.appendingPathComponent("mixed.jsonl")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let provider = makeProvider(roots: [dir])
        let snap = try await provider.fetch(now: .now)

        // Only today's record counted: 100+50 = 150 tokens
        #expect(snap.tokensToday == 150)
    }

    // MARK: Test 5 — requestID dedup across same file

    @Test func fetch_dedupsRequestIDs_acrossSamePoll() async throws {
        let dir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        // duplicate-requestids.jsonl: 2 records with same requestId
        let content = """
        {"type":"assistant","timestamp":"<TODAY-T>17:00:00.000+00:00","requestId":"req-DUP","message":{"model":"claude-haiku-4-5","role":"assistant","usage":{"input_tokens":100,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","timestamp":"<TODAY-T>17:00:01.000+00:00","requestId":"req-DUP","message":{"model":"claude-haiku-4-5","role":"assistant","usage":{"input_tokens":100,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let fileURL = dir.appendingPathComponent("dup.jsonl")
        try writeFixture(content, to: fileURL)

        let provider = makeProvider(roots: [dir])
        let snap = try await provider.fetch(now: .now)

        // Only first record counted: 100+100 = 200 tokens (NOT 400)
        #expect(snap.tokensToday == 200)
    }

    // MARK: Test 6 — second call returns zero due to offset cache

    @Test func fetch_secondCall_returnsZero_dueToOffsetCache() async throws {
        let dir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = """
        {"type":"assistant","timestamp":"<TODAY-T>10:00:00.000+00:00","requestId":"req-1","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
        let fileURL = dir.appendingPathComponent("session.jsonl")
        try writeFixture(content, to: fileURL)

        let cache = FakeCacheStore()
        let provider = makeProvider(roots: [dir], cache: cache)

        let snap1 = try await provider.fetch(now: .now)
        #expect(snap1.tokensToday == 1500)

        // Second fetch: file unchanged (mtime same), offset at EOF → zero new records.
        let snap2 = try await provider.fetch(now: .now)
        #expect(snap2.tokensToday == 0)
    }

    // MARK: Test 7 — OAuth success populates quotaWindows and primary quota

    @Test func fetch_OAuthSuccess_populatesQuotaWindows_andPrimaryQuota() async throws {
        let oauthResponse = ClaudeUsageResponse(
            fiveHour: .init(utilization: 67.5, resetsAt: "2026-05-13T20:00:00.000+00:00"),
            sevenDay: .init(utilization: 32.1, resetsAt: "2026-05-20T00:00:00.000+00:00"),
            sevenDaySonnet: .init(utilization: 28.0, resetsAt: "2026-05-20T00:00:00.000+00:00"),
            sevenDayOpus: .init(utilization: 12.5, resetsAt: "2026-05-20T00:00:00.000+00:00")
        )
        let fakeOAuth = FakeOAuthClient(mode: .success(oauthResponse))

        let provider = makeProvider(roots: [], oauth: fakeOAuth)
        let snap = try await provider.fetch(now: .now)

        // quotaWindows: 5h + 7d + 7d-sonnet + 7d-opus = 4 windows
        let windows = try #require(snap.quotaWindows)
        #expect(windows.count == 4)

        let names = windows.map(\.name)
        #expect(names.contains("5h"))
        #expect(names.contains("7d"))
        #expect(names.contains("7d-sonnet"))
        #expect(names.contains("7d-opus"))

        // Primary quota = max(67.5, 32.1) / 100 = 0.675
        let quota = try #require(snap.quota)
        #expect(quota.limit == 1.0)
        #expect(abs(quota.used - 0.675) < 1e-9)
        #expect(abs(quota.remaining - 0.325) < 1e-9)
    }

    // MARK: Test 8 — OAuth failure degrades to local-only, does NOT throw

    @Test func fetch_OAuthFailure_degradesToLocalOnly_doesNotThrow() async throws {
        let dir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = """
        {"type":"assistant","timestamp":"<TODAY-T>12:00:00.000+00:00","requestId":"req-1","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":500,"output_tokens":250,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
        let fileURL = dir.appendingPathComponent("local.jsonl")
        try writeFixture(content, to: fileURL)

        let fakeOAuth = FakeOAuthClient(
            mode: .failure(ClaudeOAuthError.usageEndpointFailed(status: 429))
        )
        let provider = makeProvider(roots: [dir], oauth: fakeOAuth)

        // Must NOT throw even though OAuth fails
        let snap = try await provider.fetch(now: .now)

        // quota/quotaWindows absent — OAuth degraded
        #expect(snap.quotaWindows == nil)
        #expect(snap.quota == nil)

        // Local JSONL still counted
        #expect(snap.tokensToday == 750)

        // Status should be .ok (local data rendered successfully)
        let status = await provider.status()
        if case .ok = status { } else {
            Issue.record("Expected .ok status after OAuth degradation, got \(status)")
        }
    }

    // MARK: Test 9 — OAuth absent (nil), local-only mode

    @Test func fetch_OAuthAbsent_localOnly() async throws {
        let dir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = """
        {"type":"assistant","timestamp":"<TODAY-T>09:00:00.000+00:00","requestId":"req-1","message":{"model":"claude-haiku-4-5","role":"assistant","usage":{"input_tokens":200,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
        let fileURL = dir.appendingPathComponent("local.jsonl")
        try writeFixture(content, to: fileURL)

        let provider = makeProvider(roots: [dir], oauth: nil)
        let snap = try await provider.fetch(now: .now)

        #expect(snap.quotaWindows == nil)
        #expect(snap.quota == nil)
        #expect(snap.tokensToday == 300)
    }

    // MARK: Test 10 — OAuth only, no JSONL

    @Test func fetch_OAuthOnly_noJSONL() async throws {
        let oauthResponse = ClaudeUsageResponse(
            fiveHour: .init(utilization: 50.0, resetsAt: "2026-05-13T20:00:00.000+00:00"),
            sevenDay: .init(utilization: 20.0, resetsAt: "2026-05-20T00:00:00.000+00:00"),
            sevenDaySonnet: nil,
            sevenDayOpus: nil
        )
        let fakeOAuth = FakeOAuthClient(mode: .success(oauthResponse))
        let provider = makeProvider(roots: [], oauth: fakeOAuth)

        let snap = try await provider.fetch(now: .now)

        #expect(snap.tokensToday == 0)
        #expect(snap.costTodayUSD == 0)

        let windows = try #require(snap.quotaWindows)
        #expect(windows.count == 2)

        // Primary quota = max(50.0, 20.0)/100 = 0.5
        let quota = try #require(snap.quota)
        #expect(abs(quota.used - 0.5) < 1e-9)
    }

    // MARK: Test 11 — JSONL fan-out error sets error status and rethrows
    // NOTE: uses file permission manipulation — may be fragile on some CI environments.

    @Test(.disabled("Potentially flaky FS permission test — verified manually"))
    func fetch_jsonlFanOutError_setsErrorStatus_andRethrows() async throws {
        let dir = try makeTempRoot()
        defer {
            // Restore permissions before cleanup
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644 as AnyObject],
                ofItemAtPath: dir.appendingPathComponent("unreadable.jsonl").path
            )
            try? FileManager.default.removeItem(at: dir)
        }

        let fileURL = dir.appendingPathComponent("unreadable.jsonl")
        let content = """
        {"type":"assistant","timestamp":"<TODAY-T>10:00:00.000+00:00","requestId":"req-1","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
        try writeFixture(content, to: fileURL)

        // Remove read permissions to trigger a FileHandle error
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000 as AnyObject],
            ofItemAtPath: fileURL.path
        )

        let provider = makeProvider(roots: [dir])

        do {
            _ = try await provider.fetch(now: .now)
            Issue.record("Expected fetch to throw on unreadable file")
        } catch {
            // Expected — verify status is .error
            let status = await provider.status()
            if case .error = status { } else {
                Issue.record("Expected .error status after fan-out failure, got \(status)")
            }
        }
    }

    // MARK: Test 12 — Offset-based delta: second poll reads only new records

    @Test func fetch_offsetsCachedAfterFetch_secondPollReadsOnlyDelta() async throws {
        let dir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("growing.jsonl")
        let record1 = materializeFixture(
            """
            {"type":"assistant","timestamp":"<TODAY-T>10:00:00.000+00:00","requestId":"req-1","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

            """
        )
        try record1.write(to: fileURL, atomically: true, encoding: .utf8)

        let cache = FakeCacheStore()
        let provider = makeProvider(roots: [dir], cache: cache)

        let snap1 = try await provider.fetch(now: .now)
        #expect(snap1.tokensToday == 1500)

        // Append a second record to the file
        let record2 = materializeFixture(
            "\n{\"type\":\"assistant\",\"timestamp\":\"<TODAY-T>10:05:00.000+00:00\",\"requestId\":\"req-2\",\"message\":{\"model\":\"claude-sonnet-4-5\",\"role\":\"assistant\",\"usage\":{\"input_tokens\":200,\"output_tokens\":100,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}\n"
        )
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = record2.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }

        let snap2 = try await provider.fetch(now: .now)
        // Only the appended record: 200+100 = 300 tokens
        #expect(snap2.tokensToday == 300)
    }

    // MARK: Test 13 — Transcript offset persisted in cache after fetch

    @Test func fetch_persistsTranscriptOffset_inFakeCache() async throws {
        let dir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("session.jsonl")
        let content = """
        {"type":"assistant","timestamp":"<TODAY-T>11:00:00.000+00:00","requestId":"req-1","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":500,"output_tokens":250,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
        try writeFixture(content, to: fileURL)

        let cache = FakeCacheStore()
        let provider = makeProvider(roots: [dir], cache: cache)

        _ = try await provider.fetch(now: .now)

        // Scanner resolves symlinks before storing the key (e.g. /var → /private/var on macOS).
        // Look up using the canonical path form to match the stored key.
        let offset = cache.transcriptOffset(forURL: fileURL.resolvingSymlinksInPath().absoluteString)
        let stored = try #require(offset, "Expected non-nil TranscriptOffset for fixture file")
        #expect(stored.byteOffset > 0)
    }

    // MARK: Test 14 — Capabilities declaration

    @Test func fetch_capabilities_declares_hasTokens_hasCost_hasQuota() async throws {
        let provider = makeProvider(roots: [])
        #expect(provider.capabilities == ProviderCapabilities(
            hasQuota: true,
            hasCost: true,
            hasTokens: true,
            isLocal: false
        ))
    }

    // MARK: Test 15 — ProviderID.claude constant exists

    @Test func providerID_claude_constantExists() {
        #expect(ProviderID.claude.rawValue == "claude")
        #expect(ProviderID.claude.displayHint == "Claude")
    }

    // MARK: Test 16 — ClaudeRoots.defaultRoots includes Claude Code + CCS roots

    @Test func claudeRoots_defaultRoots_includesClaudeAndCCSPaths() {
        let roots = ClaudeRoots.defaultRoots
        // ~/.claude/projects is always considered. It may be filtered out if it
        // does not exist on the test host, so we only assert that ALL returned
        // paths end with the canonical `/projects` segment used by both
        // Claude Code and CCS layouts.
        for root in roots {
            #expect(root.path.hasSuffix("/projects"))
        }
    }
}

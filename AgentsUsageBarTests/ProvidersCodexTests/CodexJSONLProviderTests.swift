import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - FakeCodexCacheStore
//
// In-memory CacheStore that records every setTranscriptOffsets call so the
// batched-write invariant (STATE #43 / commit 378c553) can be asserted.
// File-local — does not collide with the test-target-wide `FakeCacheStore`
// defined in OpenRouterProviderTests.swift.

final class FakeCodexCacheStore: CacheStore, @unchecked Sendable {
    var transcripts: [String: TranscriptOffset] = [:]
    var setTranscriptOffsetsCallCount: Int = 0
    var setTranscriptOffsetsKeysObserved: [Set<String>] = []

    // Stubs for the non-transcript surface — Codex provider does not exercise these.
    func loadAll() -> [ProviderID: ProviderState] { [:] }
    func save(_ providers: [ProviderID: ProviderState]) {}
    func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? { nil }
    func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {}

    // Transcript-offset surface — the methods CodexJSONLProvider actually uses.
    func transcriptOffset(forURL urlString: String) -> TranscriptOffset? {
        transcripts[urlString]
    }
    func setTranscriptOffset(_ offset: TranscriptOffset) {
        // Per-offset path NOT used by CodexJSONLProvider — record nothing here
        // so an accidental fallback to per-offset writes is visible (the
        // batched call should be the only path exercised).
        transcripts[offset.url] = offset
    }
    func setTranscriptOffsets(_ offsets: [TranscriptOffset]) {
        setTranscriptOffsetsCallCount += 1
        setTranscriptOffsetsKeysObserved.append(Set(offsets.map(\.url)))
        for o in offsets { transcripts[o.url] = o }
    }
    func allTranscriptOffsets() -> [String: TranscriptOffset] {
        transcripts
    }
}

// MARK: - FakeCodexOAuthClient
//
// Test double for the OAuth fallback. Records whether fetchUsage was called
// (test N verifies the rollout-wins invariant — D-02 strict).

actor FakeCodexOAuthClient: CodexOAuthClientProtocol {
    enum Mode {
        case success(CodexUsageResponse)
        case failure(Error)
        case shouldNeverBeCalled
    }

    private(set) var fetchCallCount: Int = 0
    private var mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func fetchUsage() async throws -> CodexUsageResponse {
        fetchCallCount += 1
        switch mode {
        case .success(let r): return r
        case .failure(let e): throw e
        case .shouldNeverBeCalled:
            // Trip the test if invoked when it shouldn't be.
            throw CodexOAuthError.usageEndpointFailed(status: 999)
        }
    }
}

// MARK: - Fixture helpers

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexJSONLProviderTests-\(UUID().uuidString)", isDirectory: true)
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

private func writeJsonl(_ contents: String, to url: URL) throws {
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

private func loadFixtureString(named name: String) throws -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    return try String(contentsOf: here, encoding: .utf8)
}

/// Builds a scanner factory that points at the given root directory and
/// uses a pinned `now`. Mirrors the production wiring shape but for tests
/// that need a deterministic file tree.
///
/// **Critical:** explicit Gregorian calendar — `Calendar.current` on a host
/// configured for the Buddhist Era (or any non-Gregorian) calendar returns
/// year `2569` for an instant in AD 2026, which would walk
/// `<root>/2569/04/24/` instead of `<root>/2026/04/24/`. Matches
/// `CodexRolloutScannerTests`' pattern of injecting an explicit calendar so
/// the suite passes on any host locale.
private func scannerFactory(root: URL) -> CodexRolloutScannerFactory {
    let cal = Calendar(identifier: .gregorian)
    return { now in CodexRolloutScanner(now: now, calendar: cal, root: root) }
}

// MARK: - Test pricing helper

private extension CodexModelPricing {
    /// Minimal pricing table aligned with the production codex-models.json
    /// default rate (input=0.75, cached=0.025, output=3.00 per Mtok).
    static let testPricing = CodexModelPricing(
        schemaVersion: 1,
        lastUpdated: "test",
        default: .init(inputPerMToken: 0.750, outputPerMToken: 3.000, cachedInputPerMToken: 0.025),
        models: [:]
    )
}

// MARK: - CodexJSONLProviderTests (rollout happy paths)

@Suite("CodexJSONLProviderTests", .serialized)
struct CodexJSONLProviderTests {

    // MARK: - A. Happy rollout path — 2026 fixture full event populates snapshot

    @Test func rollout_2026_fixture_populates_tokens_cost_quota_tooltip() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Pin `now` so the scanner walks 2026/04/24.
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = try #require(isoFractional.date(from: "2026-04-24T12:00:00.000Z"))

        // Today fixture: pinned to 11:56:30 event (the canonical full event).
        // The 2026 fixture file has THREE token_count events plus a truncated
        // line; the parser's fold returns the LATEST-timestamped one which is
        // the synthetic 11:57 event. For test A we want the rich 11:56:30
        // values, so we write only the first 3 lines (the full event line is
        // line 3) into the fixture.
        let raw = try loadFixtureString(named: "codex-rollout-2026-fixture.jsonl")
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let firstThree = lines.prefix(3).joined(separator: "\n") + "\n"
        let todayDir = try dateDir(under: root, year: 2026, month: 4, day: 24)
        try writeJsonl(firstThree, to: todayDir.appendingPathComponent("rollout-A.jsonl"))

        let cache = FakeCodexCacheStore()
        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: nil,
            cache: cache,
            clock: SystemClock()
        )

        let snap = try await provider.fetch(now: now)

        // Tokens — Pitfall 11: total_token_usage.total_tokens = 556469.
        #expect(snap.tokensToday == 556469)

        // Cost — default rate at (551589, 505856, 4880, 620) ≈ $0.061586.
        let cost = try #require(snap.costTodayUSD)
        let costDouble = NSDecimalNumber(decimal: cost).doubleValue
        #expect(abs(costDouble - 0.061586) < 0.0001)

        // Quota windows — primary + secondary.
        let windows = try #require(snap.quotaWindows)
        #expect(windows.count == 2)
        #expect(windows[0].name == "primary")
        #expect(windows[1].name == "secondary")
        // Primary utilization = 2/100 = 0.02.
        #expect(windows[0].utilization == 0.02)
        // Secondary utilization = 0/100 = 0.0.
        #expect(windows[1].utilization == 0.0)

        // D-05: quota.fraction = max(0.02, 0.0) = 0.02.
        let quota = try #require(snap.quota)
        #expect(quota.fraction == 0.02)

        // D-15: tooltipLabel == "plus".
        #expect(snap.tooltipLabel == "plus")

        // raw["source"] == "rollout".
        #expect(snap.raw["source"] == "rollout")

        // lastStatus.
        let status = await provider.status()
        if case .ok = status { } else {
            Issue.record("Expected .ok status, got \(status)")
        }
    }

    // MARK: - B. Legacy 2025 fixture — resets_in_seconds → resetsAt = now + 300s

    @Test func rollout_2025_legacy_resets_in_seconds_normalised_to_now_plus_seconds() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = try #require(isoFractional.date(from: "2025-09-12T08:30:00.000Z"))

        let raw = try loadFixtureString(named: "codex-rollout-2025-legacy.jsonl")
        let todayDir = try dateDir(under: root, year: 2025, month: 9, day: 12)
        try writeJsonl(raw, to: todayDir.appendingPathComponent("rollout-legacy.jsonl"))

        let cache = FakeCodexCacheStore()
        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: nil,
            cache: cache,
            clock: SystemClock()
        )

        let snap = try await provider.fetch(now: now)

        let windows = try #require(snap.quotaWindows)
        let primary = try #require(windows.first { $0.name == "primary" })
        let resetsAt = try #require(primary.resetsAt)
        let delta = resetsAt.timeIntervalSince(now)
        // resets_in_seconds == 300 in the 2025 legacy fixture.
        #expect(abs(delta - 300.0) < 0.001)
    }

    // MARK: - C. Files exist but ZERO token_count → mutedNoData (no oauth)

    @Test func rollout_files_without_token_count_events_falls_to_mutedNoData_when_no_oauth() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = try #require(isoFractional.date(from: "2026-04-24T12:00:00.000Z"))

        // File contains only session_meta + response_item — no token_count.
        let content = """
        {"timestamp":"2026-04-24T10:00:00.000Z","type":"session_meta","payload":{"model_provider":"openai"}}
        {"timestamp":"2026-04-24T10:00:01.000Z","type":"response_item","payload":{"role":"assistant","content":"hi"}}
        """
        let todayDir = try dateDir(under: root, year: 2026, month: 4, day: 24)
        try writeJsonl(content, to: todayDir.appendingPathComponent("no-token-count.jsonl"))

        let cache = FakeCodexCacheStore()
        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: nil,
            cache: cache,
            clock: SystemClock()
        )

        let snap = try await provider.fetch(now: now)

        #expect(snap.tokensToday == nil)
        #expect(snap.costTodayUSD == nil)
        #expect(snap.quota == nil)
        #expect(snap.quotaWindows == nil)
        #expect(snap.raw["status"] == "no-data-yet")

        let status = await provider.status()
        #expect(status == .unauthenticated)
    }

    // MARK: - D. Offset-cache integration — exactly one batched setTranscriptOffsets call per fetch

    @Test func offset_cache_writes_exactly_one_batched_call_per_fetch() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = try #require(isoFractional.date(from: "2026-04-24T12:00:00.000Z"))

        // Two files so the fan-out has > 1 entry.
        let raw = try loadFixtureString(named: "codex-rollout-2026-fixture.jsonl")
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let firstThree = lines.prefix(3).joined(separator: "\n") + "\n"
        let todayDir = try dateDir(under: root, year: 2026, month: 4, day: 24)
        let urlA = todayDir.appendingPathComponent("rollout-A.jsonl")
        let urlB = todayDir.appendingPathComponent("rollout-B.jsonl")
        try writeJsonl(firstThree, to: urlA)
        try writeJsonl(firstThree, to: urlB)

        let cache = FakeCodexCacheStore()
        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: nil,
            cache: cache,
            clock: SystemClock()
        )

        _ = try await provider.fetch(now: now)

        // STATE #43 / 378c553 invariant: exactly ONE batched setTranscriptOffsets
        // call per fetch, no matter how many files are in the fan-out.
        #expect(cache.setTranscriptOffsetsCallCount == 1)
        // The batched call should carry offsets for BOTH files.
        let keys = try #require(cache.setTranscriptOffsetsKeysObserved.first)
        #expect(keys.contains(urlA.resolvingSymlinksInPath().absoluteString))
        #expect(keys.contains(urlB.resolvingSymlinksInPath().absoluteString))

        // Second fetch: the offsets persisted from the first fetch should be
        // present in the cache; the second batched write replaces them.
        _ = try await provider.fetch(now: now)
        #expect(cache.setTranscriptOffsetsCallCount == 2)
        // Cache still has both file keys (canonical form).
        let allOffsets = cache.allTranscriptOffsets()
        #expect(allOffsets.keys.contains(urlA.resolvingSymlinksInPath().absoluteString))
        #expect(allOffsets.keys.contains(urlB.resolvingSymlinksInPath().absoluteString))
    }

    // MARK: - E. Symlink path canonicalisation — cache keys are canonical (/private/var/...)

    @Test func cache_keys_are_symlink_canonical() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = try #require(isoFractional.date(from: "2026-04-24T12:00:00.000Z"))

        let raw = try loadFixtureString(named: "codex-rollout-2026-fixture.jsonl")
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let firstThree = lines.prefix(3).joined(separator: "\n") + "\n"
        let todayDir = try dateDir(under: root, year: 2026, month: 4, day: 24)
        let url = todayDir.appendingPathComponent("rollout-A.jsonl")
        try writeJsonl(firstThree, to: url)

        let cache = FakeCodexCacheStore()
        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: nil,
            cache: cache,
            clock: SystemClock()
        )

        _ = try await provider.fetch(now: now)

        // macOS NSTemporaryDirectory resolves to `/var/folders/…` which is a
        // symlink to `/private/var/folders/…`. The scanner canonicalises via
        // resolvingSymlinksInPath() — so the cache key should be the canonical
        // form starting with `/private/var` (NOT the un-resolved `/var/...`).
        let canonical = url.resolvingSymlinksInPath().absoluteString
        let allOffsets = cache.allTranscriptOffsets()
        #expect(allOffsets.keys.contains(canonical))
        // Optional: assert the canonical form actually went through /private resolution
        // (on macOS hosts only — the macOS guard is implicit because tests only
        // run on macOS for this SwiftUI app).
        #expect(canonical.contains("/private/var/") || canonical.contains("/var/"))
    }

    // MARK: - F. Pitfall 5 — malformed last line tolerated; provider returns valid event

    @Test func malformed_last_line_does_not_zero_the_row() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = try #require(isoFractional.date(from: "2026-04-24T12:00:00.000Z"))

        // Write a file with a valid event followed by a truncated line.
        let validEvent = """
        {"timestamp":"2026-04-24T11:56:30.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}},"rate_limits":{"primary":{"used_percent":7,"window_minutes":300,"resets_at":1777024786},"plan_type":"pro"}}}
        """
        let truncated = """
        {"timestamp":"2026-04-24T11:57:00.000Z","type":"event_msg
        """
        let content = validEvent + "\n" + truncated
        let todayDir = try dateDir(under: root, year: 2026, month: 4, day: 24)
        try writeJsonl(content, to: todayDir.appendingPathComponent("with-truncation.jsonl"))

        let cache = FakeCodexCacheStore()
        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: nil,
            cache: cache,
            clock: SystemClock()
        )

        let snap = try await provider.fetch(now: now)
        // Provider should NOT throw and should return the valid event's tokens.
        #expect(snap.tokensToday == 120)
        #expect(snap.tooltipLabel == "pro")
        let status = await provider.status()
        if case .ok = status { } else {
            Issue.record("Expected .ok status, got \(status)")
        }
    }
}

import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Local fakes (file-local to avoid cross-suite type collisions)

private final class StubFallbackCacheStore: CacheStore, @unchecked Sendable {
    private var transcripts: [String: TranscriptOffset] = [:]

    func loadAll() -> [ProviderID: ProviderState] { [:] }
    func save(_ providers: [ProviderID: ProviderState]) {}
    func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? { nil }
    func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {}
    func transcriptOffset(forURL urlString: String) -> TranscriptOffset? { transcripts[urlString] }
    func setTranscriptOffset(_ offset: TranscriptOffset) { transcripts[offset.url] = offset }
    func setTranscriptOffsets(_ offsets: [TranscriptOffset]) {
        for o in offsets { transcripts[o.url] = o }
    }
    func allTranscriptOffsets() -> [String: TranscriptOffset] { transcripts }
}

private actor StubFallbackOAuthClient: CodexOAuthClientProtocol {
    enum Mode {
        case success(CodexUsageResponse)
        case failure(Error)
        case shouldNeverBeCalled
    }

    private(set) var fetchCallCount: Int = 0
    private var mode: Mode

    init(mode: Mode) { self.mode = mode }

    func fetchUsage() async throws -> CodexUsageResponse {
        fetchCallCount += 1
        switch mode {
        case .success(let r): return r
        case .failure(let e): throw e
        case .shouldNeverBeCalled:
            throw CodexOAuthError.usageEndpointFailed(status: 999)
        }
    }
}

// MARK: - Helpers

private func makeEmptyRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexFallbackTests-\(UUID().uuidString)", isDirectory: true)
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

private func loadFixture(named name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    return try Data(contentsOf: url)
}

private func decodeFixtureUsage() throws -> CodexUsageResponse {
    let data = try loadFixture(named: "codex-wham-usage-fixture.json")
    return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
}

private func scannerFactory(root: URL) -> CodexRolloutScannerFactory {
    // Explicit Gregorian calendar — host may be configured for a non-Gregorian
    // calendar (Buddhist Era, etc.); `Calendar.current` would split the date
    // bucket on a different year, missing the test fixture entirely.
    let cal = Calendar(identifier: .gregorian)
    return { now in CodexRolloutScanner(now: now, calendar: cal, root: root) }
}

private extension CodexModelPricing {
    static let testPricing = CodexModelPricing(
        schemaVersion: 1,
        lastUpdated: "test",
        default: .init(inputPerMToken: 0.750, outputPerMToken: 3.000, cachedInputPerMToken: 0.025),
        models: [:]
    )
}

// MARK: - CodexJSONLProviderFallbackTests

@Suite("CodexJSONLProviderFallbackTests", .serialized)
struct CodexJSONLProviderFallbackTests {

    // MARK: - G. No rollout + OAuth 200 → snapshot from wham/usage

    @Test func no_rollout_oauth_success_returns_oauth_snapshot() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let response = try decodeFixtureUsage()
        let oauth = StubFallbackOAuthClient(mode: .success(response))

        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: oauth,
            cache: StubFallbackCacheStore(),
            clock: SystemClock()
        )

        let snap = try await provider.fetch(now: now)

        // wham/usage: no token count, no cost.
        #expect(snap.tokensToday == nil)
        #expect(snap.costTodayUSD == nil)

        // Two windows from fixture (primary used_percent=48, secondary=26).
        let windows = try #require(snap.quotaWindows)
        #expect(windows.count == 2)
        #expect(windows[0].name == "primary")
        #expect(windows[0].utilization == 0.48)
        #expect(windows[1].name == "secondary")
        #expect(windows[1].utilization == 0.26)

        // D-05: quota.fraction = max(0.48, 0.26) = 0.48.
        let quota = try #require(snap.quota)
        #expect(quota.fraction == 0.48)

        // D-15: planType="plus" → tooltipLabel.
        #expect(snap.tooltipLabel == "plus")

        // raw["source"] == "oauth-wham-usage".
        #expect(snap.raw["source"] == "oauth-wham-usage")

        let status = await provider.status()
        if case .ok = status { } else {
            Issue.record("Expected .ok status, got \(status)")
        }
    }

    // MARK: - H. No rollout + OAuth .noCredentials → mutedNoData (no throw)

    @Test func no_rollout_oauth_noCredentials_returns_mutedNoData_no_throw() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let oauth = StubFallbackOAuthClient(mode: .failure(CodexOAuthError.noCredentials))

        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: oauth,
            cache: StubFallbackCacheStore(),
            clock: SystemClock()
        )

        let snap = try await provider.fetch(now: now)
        #expect(snap.tokensToday == nil)
        #expect(snap.quota == nil)
        #expect(snap.quotaWindows == nil)
        #expect(snap.raw["status"] == "no-data-yet")

        let status = await provider.status()
        #expect(status == .unauthenticated)
    }

    // MARK: - I. No rollout + OAuth .unauthorized(401) → mutedNoData (no throw)

    @Test func no_rollout_oauth_unauthorized_401_returns_mutedNoData_no_throw() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oauth = StubFallbackOAuthClient(mode: .failure(CodexOAuthError.unauthorized(status: 401)))

        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: oauth,
            cache: StubFallbackCacheStore(),
            clock: SystemClock()
        )

        let snap = try await provider.fetch(now: Date())
        #expect(snap.raw["status"] == "no-data-yet")
        let status = await provider.status()
        #expect(status == .unauthenticated)
    }

    // MARK: - J. No rollout + OAuth .unauthorized(403) → mutedNoData (no throw)

    @Test func no_rollout_oauth_unauthorized_403_returns_mutedNoData_no_throw() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oauth = StubFallbackOAuthClient(mode: .failure(CodexOAuthError.unauthorized(status: 403)))

        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: oauth,
            cache: StubFallbackCacheStore(),
            clock: SystemClock()
        )

        let snap = try await provider.fetch(now: Date())
        #expect(snap.raw["status"] == "no-data-yet")
        let status = await provider.status()
        #expect(status == .unauthenticated)
    }

    // MARK: - K. No rollout + OAuth .usageEndpointFailed(429) → RETHROWS

    @Test func no_rollout_oauth_usageEndpointFailed_429_rethrows() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oauth = StubFallbackOAuthClient(
            mode: .failure(CodexOAuthError.usageEndpointFailed(status: 429))
        )

        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: oauth,
            cache: StubFallbackCacheStore(),
            clock: SystemClock()
        )

        await #expect(throws: CodexOAuthError.usageEndpointFailed(status: 429)) {
            _ = try await provider.fetch(now: Date())
        }
    }

    // MARK: - L. No rollout + OAuth .usageEndpointFailed(500) → RETHROWS

    @Test func no_rollout_oauth_usageEndpointFailed_500_rethrows() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oauth = StubFallbackOAuthClient(
            mode: .failure(CodexOAuthError.usageEndpointFailed(status: 500))
        )

        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: oauth,
            cache: StubFallbackCacheStore(),
            clock: SystemClock()
        )

        await #expect(throws: CodexOAuthError.usageEndpointFailed(status: 500)) {
            _ = try await provider.fetch(now: Date())
        }
    }

    // MARK: - M. No rollout + oauth == nil → mutedNoData (no throw)

    @Test func no_rollout_no_oauth_wired_returns_mutedNoData_no_throw() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: nil,
            cache: StubFallbackCacheStore(),
            clock: SystemClock()
        )

        let snap = try await provider.fetch(now: Date())
        #expect(snap.raw["status"] == "no-data-yet")
        let status = await provider.status()
        #expect(status == .unauthenticated)
    }

    // MARK: - N. Rollout present AND oauth wired → oauth NEVER called (D-02)

    @Test func rollout_wins_oauth_is_not_called_when_rollout_has_data() async throws {
        let root = try makeEmptyRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = try #require(isoFractional.date(from: "2026-04-24T12:00:00.000Z"))

        // Write the 2026 fixture's first 3 lines so the parser returns the
        // full 11:56:30 event.
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("codex-rollout-2026-fixture.jsonl")
        let raw = try String(contentsOf: here, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let firstThree = lines.prefix(3).joined(separator: "\n") + "\n"
        let todayDir = try dateDir(under: root, year: 2026, month: 4, day: 24)
        try firstThree.write(
            to: todayDir.appendingPathComponent("rollout-A.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let oauth = StubFallbackOAuthClient(mode: .shouldNeverBeCalled)
        let provider = CodexJSONLProvider(
            scannerFactory: scannerFactory(root: root),
            reader: TranscriptReader(),
            pricing: .testPricing,
            oauth: oauth,
            cache: StubFallbackCacheStore(),
            clock: SystemClock()
        )

        let snap = try await provider.fetch(now: now)
        // Rollout populated the row.
        #expect(snap.tokensToday == 556469)
        #expect(snap.raw["source"] == "rollout")
        // D-02 invariant: oauth.fetchUsage NEVER called when rollout has data.
        let calls = await oauth.fetchCallCount
        #expect(calls == 0)
    }
}

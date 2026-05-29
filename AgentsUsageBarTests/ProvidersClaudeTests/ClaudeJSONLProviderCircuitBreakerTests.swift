import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - CountingOAuthClient — counts getUsage call attempts

/// Test double that counts how many times `getUsage()` was invoked AND lets the test
/// configure success/failure per call (or for all calls).
actor CountingOAuthClient: ClaudeOAuthClientProtocol {
    enum Mode {
        case alwaysThrow(Error)
        case alwaysSucceed(ClaudeUsageResponse)
        /// Returns scripted results in order; once exhausted, repeats the last entry.
        case scripted([Result<ClaudeUsageResponse, Error>])
    }

    private var mode: Mode
    private(set) var callCount: Int = 0
    private var scriptIndex: Int = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func getUsage() async throws -> ClaudeUsageResponse {
        callCount += 1
        switch mode {
        case .alwaysThrow(let err):
            throw err
        case .alwaysSucceed(let r):
            return r
        case .scripted(let entries):
            let i = min(scriptIndex, entries.count - 1)
            scriptIndex += 1
            switch entries[i] {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
    }

    func getCount() -> Int { callCount }
}

// MARK: - Helpers

private extension ClaudeModelPricing {
    static let cbTestPricing = ClaudeModelPricing(
        schemaVersion: 1,
        lastUpdated: "test",
        default: .init(inputPer1M: 3.00, outputPer1M: 15.00, cacheWritePer1M: 3.75, cacheReadPer1M: 0.30),
        models: [
            "claude-sonnet-4-5": .init(
                inputPer1M: 3.00, outputPer1M: 15.00,
                cacheWritePer1M: 3.75, cacheReadPer1M: 0.30
            ),
        ]
    )
}

private func makeCBProvider(
    roots: [URL] = [],
    oauth: (any ClaudeOAuthClientProtocol)?,
    clock: any Clock = SystemClock()
) -> ClaudeJSONLProvider {
    ClaudeJSONLProvider(
        reader: TranscriptReader(),
        scanner: TranscriptDirectoryScanner(),
        pricing: .cbTestPricing,
        oauth: oauth,
        cache: FakeCacheStore(),
        clock: clock,
        roots: roots
    )
}

private func makeTempRootDir() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ClaudeJSONLProviderCircuitBreakerTests-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

private func writeJSONLFixture(_ content: String, to url: URL) throws {
    let today = TodayHelper.formatYYYYMMDD(.now)
    let materialized = content.replacingOccurrences(of: "<TODAY-T>", with: today + "T")
    try materialized.write(to: url, atomically: true, encoding: .utf8)
}

private func makeOAuthSuccessResponse() -> ClaudeUsageResponse {
    ClaudeUsageResponse(
        fiveHour: .init(utilization: 25.0, resetsAt: "2026-05-13T20:00:00.000+00:00"),
        sevenDay: .init(utilization: 12.0, resetsAt: "2026-05-20T00:00:00.000+00:00"),
        sevenDaySonnet: nil,
        sevenDayOpus: nil
    )
}

// MARK: - Tests

@Suite("ClaudeJSONLProviderCircuitBreakerTests", .serialized)
struct ClaudeJSONLProviderCircuitBreakerTests {

    // MARK: Test 1 — breaker trips after 3 consecutive 429s

    @Test("oauthBreaker_trips_after_3_consecutive_429")
    func oauthBreaker_trips_after_3_consecutive_429() async throws {
        let fake = CountingOAuthClient(
            mode: .alwaysThrow(ClaudeOAuthError.usageEndpointFailed(status: 429))
        )
        let provider = makeCBProvider(oauth: fake)

        // First 3 fetches each call oauth; on the 3rd call the breaker trips.
        // The 4th fetch SKIPS oauth (breaker is open).
        for _ in 0..<4 {
            let snap = try await provider.fetch(now: .now)
            #expect(snap.quotaWindows == nil)
        }

        let count = await fake.getCount()
        #expect(count == 3, "Expected exactly 3 oauth.getUsage calls before breaker trips, got \(count)")
    }

    // MARK: Test 2 — 5xx errors do NOT trip the OAuth-usage breaker

    @Test("oauthBreaker_does_not_trip_on_5xx")
    func oauthBreaker_does_not_trip_on_5xx() async throws {
        let fake = CountingOAuthClient(
            mode: .alwaysThrow(ClaudeOAuthError.usageEndpointFailed(status: 500))
        )
        let provider = makeCBProvider(oauth: fake)

        // 5 fetches — none should trip the 429-specific breaker.
        for _ in 0..<5 {
            _ = try await provider.fetch(now: .now)
        }

        let count = await fake.getCount()
        #expect(count == 5, "5xx should not increment the OAuth-usage breaker; expected 5 calls, got \(count)")
    }

    // MARK: Test 3 — success in between resets the breaker count

    @Test("oauthBreaker_resets_on_success")
    func oauthBreaker_resets_on_success() async throws {
        let response = makeOAuthSuccessResponse()
        // 2 × 429 + success + 429 → breaker still closed because success reset the count.
        let fake = CountingOAuthClient(mode: .scripted([
            .failure(ClaudeOAuthError.usageEndpointFailed(status: 429)),
            .failure(ClaudeOAuthError.usageEndpointFailed(status: 429)),
            .success(response),
            .failure(ClaudeOAuthError.usageEndpointFailed(status: 429)),
        ]))
        let provider = makeCBProvider(oauth: fake)

        for _ in 0..<4 {
            _ = try await provider.fetch(now: .now)
        }

        let count = await fake.getCount()
        #expect(count == 4, "Success between 429s must reset the breaker count and allow further calls; expected 4, got \(count)")
    }

    // MARK: Test 4 — breaker half-opens after cooldown

    @Test("oauthBreaker_halfOpens_after_cooldown")
    func oauthBreaker_halfOpens_after_cooldown() async throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        nonisolated(unsafe) var t = t0
        let clock = VirtualClock { t }

        let response = makeOAuthSuccessResponse()
        let fake = CountingOAuthClient(mode: .scripted([
            .failure(ClaudeOAuthError.usageEndpointFailed(status: 429)),
            .failure(ClaudeOAuthError.usageEndpointFailed(status: 429)),
            .failure(ClaudeOAuthError.usageEndpointFailed(status: 429)),
            // After cooldown — trial allowed, this success closes the breaker
            .success(response),
        ]))
        let provider = makeCBProvider(oauth: fake, clock: clock)

        // 3 × 429 trips the breaker. ClaudeJSONLProvider passes `now` into oauthBreaker.
        for _ in 0..<3 {
            _ = try await provider.fetch(now: t)
        }
        let countAfterTrip = await fake.getCount()
        #expect(countAfterTrip == 3)

        // Immediately fetch again — breaker is open, oauth must NOT be called.
        _ = try await provider.fetch(now: t)
        let countWhileOpen = await fake.getCount()
        #expect(countWhileOpen == 3, "Breaker open: oauth must not be called")

        // Advance virtual clock past cooldown (300s + buffer).
        t = t0.addingTimeInterval(305)

        // Next fetch — breaker should half-open and allow a trial.
        _ = try await provider.fetch(now: t)
        let countAfterHalfOpen = await fake.getCount()
        #expect(countAfterHalfOpen == 4, "Half-open trial should allow one attempt after cooldown")
    }

    // MARK: Test 5 — JSONL collection still works even when OAuth is degraded

    @Test("oauthBreaker_doesNot_affect_jsonl_collection")
    func oauthBreaker_doesNot_affect_jsonl_collection() async throws {
        let dir = try makeTempRootDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = """
        {"type":"assistant","timestamp":"<TODAY-T>12:00:00.000+00:00","requestId":"req-cb-1","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":400,"output_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
        let fileURL = dir.appendingPathComponent("cb-local.jsonl")
        try writeJSONLFixture(content, to: fileURL)

        let fake = CountingOAuthClient(
            mode: .alwaysThrow(ClaudeOAuthError.usageEndpointFailed(status: 429))
        )
        let provider = makeCBProvider(roots: [dir], oauth: fake)

        // First fetch: JSONL counted; OAuth fails (1st 429).
        let snap1 = try await provider.fetch(now: .now)
        #expect(snap1.tokensToday == 600, "Local JSONL must populate tokensToday even with OAuth failing")
        #expect(snap1.quotaWindows == nil)
        #expect(snap1.quota == nil)

        // Drive 2 more fetches to fully trip the breaker.
        _ = try await provider.fetch(now: .now)
        _ = try await provider.fetch(now: .now)
        let count = await fake.getCount()
        #expect(count == 3, "Breaker should trip on 3rd 429; expected exactly 3 calls, got \(count)")

        // 4th fetch: breaker open, oauth skipped — fetch must still succeed.
        _ = try await provider.fetch(now: .now)
        let countAfter = await fake.getCount()
        #expect(countAfter == 3, "Breaker remains open; oauth call count must not increase")
    }
}

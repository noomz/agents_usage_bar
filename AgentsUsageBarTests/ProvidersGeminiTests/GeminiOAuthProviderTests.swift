import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - FakeProviderOAuthClient
//
// Test double for GeminiOAuthClientProtocol. Scripts a sequence of
// freshAccessToken / retryAfter401 results. Tracks call counts so the
// suite can verify the lazy-401 single-shot retry rule.

actor FakeProviderOAuthClient: GeminiOAuthClientProtocol {
    enum Step {
        case ok(String)
        case throwError(Error)
    }

    private var freshQueue: [Step]
    private var retryQueue: [Step]
    private(set) var freshCallCount: Int = 0
    private(set) var retryCallCount: Int = 0

    init(fresh: [Step], retry: [Step] = []) {
        self.freshQueue = fresh
        self.retryQueue = retry
    }

    func freshAccessToken(now: Date) async throws -> Secret {
        freshCallCount += 1
        guard !freshQueue.isEmpty else {
            throw GeminiOAuthError.transport(underlying: HTTPError(status: 999, message: "no fresh scripted"))
        }
        switch freshQueue.removeFirst() {
        case .ok(let s): return Secret(s)
        case .throwError(let e): throw e
        }
    }

    func retryAfter401(now: Date) async throws -> Secret {
        retryCallCount += 1
        guard !retryQueue.isEmpty else {
            throw GeminiOAuthError.transport(underlying: HTTPError(status: 999, message: "no retry scripted"))
        }
        switch retryQueue.removeFirst() {
        case .ok(let s): return Secret(s)
        case .throwError(let e): throw e
        }
    }
}

// MARK: - FakeProviderHTTPClient
//
// Scripts postJSON(bearer:) responses keyed by URL.path so quota and
// tier stubs can be independently configured. Records the most recent
// request body bytes for quota-URL calls so test G can assert
// project-id propagation.

final class FakeProviderHTTPClient: HTTPClient, @unchecked Sendable {
    struct Call {
        let url: URL
        let method: String
        let bearer: Secret?
        let bodyData: Data?
    }

    /// All mutable state is gated by `lock`. The Gemini provider issues
    /// `async let quotaResult` and `async let tierResult` concurrently
    /// against the same fake instance — both helpers race to mutate
    /// `responses` (dict) and `calls` (array). Without serialisation
    /// the dictionary's COW machinery and Array growth produce flaky
    /// behaviour (race observed across xcodebuild parallel test
    /// runners; reliably reproduced ~50% on this dev host).
    private let lock = NSLock()
    private var _responses: [String: [Result<Data, Error>]] = [:]
    private var _calls: [Call] = []

    /// Keyed by `url.path` so quota and tier stubs are independent.
    /// Setter copies the value under the lock; getter returns a
    /// defensive copy.
    var responses: [String: [Result<Data, Error>]] {
        get { lock.lock(); defer { lock.unlock() }; return _responses }
        set { lock.lock(); defer { lock.unlock() }; _responses = newValue }
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }; return _calls
    }

    private func recordCall(_ call: Call) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(call)
    }

    private func takeResponse(forPath path: String) -> Result<Data, Error>? {
        lock.lock(); defer { lock.unlock() }
        guard var queue = _responses[path], !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        _responses[path] = queue
        return first
    }

    // MARK: HTTPClient — GET

    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret,
        extraHeaders: [String: String],
        useSnakeCaseConversion: Bool,
        as type: T.Type
    ) async throws -> T {
        recordCall(.init(url: url, method: "GET", bearer: bearer, bodyData: nil))
        throw HTTPError(status: 501, message: "FakeProviderHTTPClient: GET not scripted")
    }

    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret?,
        extraHeaders: [String: String],
        useSnakeCaseConversion: Bool,
        as type: T.Type
    ) async throws -> T {
        recordCall(.init(url: url, method: "GET", bearer: bearer, bodyData: nil))
        throw HTTPError(status: 501, message: "FakeProviderHTTPClient: GET not scripted")
    }

    // MARK: HTTPClient — POST JSON (unauthenticated)

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        let enc = JSONEncoder()
        let data = try enc.encode(body)
        recordCall(.init(url: url, method: "POST", bearer: nil, bodyData: data))
        throw HTTPError(status: 501, message: "FakeProviderHTTPClient: postJSON not scripted")
    }

    // MARK: HTTPClient — POST JSON (bearer-authenticated)

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        bearer: Secret,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        // Encode body without snake_case conversion so the test can
        // assert the literal camelCase wire shape (matches production
        // URLSessionHTTPClient.postJSON(bearer:) encoder choice).
        let enc = JSONEncoder()
        let data = try enc.encode(body)
        recordCall(.init(url: url, method: "POST", bearer: bearer, bodyData: data))
        return try decode(type, urlPath: url.path)
    }

    // MARK: HTTPClient — POST form

    func postFormURLEncoded<T: Decodable & Sendable>(
        _ url: URL,
        formFields: [(String, String)],
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        recordCall(.init(url: url, method: "POST", bearer: nil, bodyData: nil))
        throw HTTPError(status: 501, message: "FakeProviderHTTPClient: postFormURLEncoded not scripted")
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, urlPath: String) throws -> T {
        guard let first = takeResponse(forPath: urlPath) else {
            throw HTTPError(status: 500, message: "FakeProviderHTTPClient: no response for \(urlPath)")
        }
        switch first {
        case .success(let data):
            // Plain JSONDecoder — matches the production
            // postJSON(bearer:) decoder choice (Gemini response types
            // declare explicit snake_case CodingKeys).
            return try JSONDecoder().decode(T.self, from: data)
        case .failure(let err):
            throw err
        }
    }

    /// Returns the most recent body bytes for a POST to `url.path`.
    func latestBody(forPath path: String) -> Data? {
        calls.last(where: { $0.url.path == path && $0.method == "POST" })?.bodyData
    }
}

// MARK: - Fixture helpers

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func loadFixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

/// URL.paths for both v1internal endpoints.
private let quotaPath = GeminiOAuthProvider.quotaURL.path
private let tierPath = GeminiOAuthProvider.tierURL.path

// MARK: - GeminiOAuthProviderTests

@Suite("GeminiOAuthProviderTests", .serialized)
struct GeminiOAuthProviderTests {

    // MARK: - A. Happy concurrent fetch

    @Test func happyPath_concurrentFetch_populatesQuotaAndTier() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeProviderHTTPClient()
        http.responses[quotaPath] = [
            .success(try loadFixtureData("gemini-quota-response-fixture.json"))
        ]
        http.responses[tierPath] = [
            .success(try loadFixtureData("gemini-loadcodeassist-fixture.json"))
        ]
        let oauth = FakeProviderOAuthClient(fresh: [.ok("FAKE-bearer-1")])

        let provider = GeminiOAuthProvider(http: http, oauth: oauth)
        let snap = try await provider.fetch(now: now)

        // D-07: tokensToday and costTodayUSD always nil.
        #expect(snap.tokensToday == nil)
        #expect(snap.costTodayUSD == nil)

        // 3 windows, one per modelId.
        let windows = try #require(snap.quotaWindows)
        #expect(windows.count == 3)
        // Stable alphabetical sort: flash, flash-lite, pro.
        #expect(windows[0].name == "gemini-2.5-flash")
        #expect(windows[1].name == "gemini-2.5-flash-lite")
        #expect(windows[2].name == "gemini-2.5-pro")
        // utilization = 1 - remainingFraction.
        #expect(abs((windows[2].utilization ?? -1) - 0.15) < 1e-9)  // pro (1 - 0.85)
        #expect(abs((windows[0].utilization ?? -1) - 0.08) < 1e-9)  // flash (1 - 0.92)
        #expect(abs((windows[1].utilization ?? -1) - 0.02) < 1e-9)  // flash-lite (1 - 0.98)

        // Primary quota = max utilisation across all windows.
        let quota = try #require(snap.quota)
        #expect(abs(quota.used - 0.15) < 1e-9)
        #expect(quota.limit == 1.0)

        // D-15 / GEMINI-03: tier "free-tier" → "Free".
        #expect(snap.tooltipLabel == "Free")
        #expect(snap.raw["source"] == "v1internal")

        // No degraded-UX marker on the happy path.
        #expect(snap.raw["note"] == nil)
        #expect(snap.raw["degraded"] == nil)

        let status = await provider.status()
        if case .ok = status { } else {
            Issue.record("Expected .ok status, got \(status)")
        }

        // OAuth invoked exactly once (no retry needed).
        let freshCalls = await oauth.freshCallCount
        let retryCalls = await oauth.retryCallCount
        #expect(freshCalls == 1)
        #expect(retryCalls == 0)
    }

    // MARK: - B. Per-model fold — multibucket → lowest fraction wins

    @Test func multiBucketPerModel_keepsLowestRemainingFraction() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeProviderHTTPClient()
        http.responses[quotaPath] = [
            .success(try loadFixtureData("gemini-quota-response-multibucket-fixture.json"))
        ]
        // Tier failure — irrelevant to this assertion.
        http.responses[tierPath] = [.failure(HTTPError(status: 500))]
        let oauth = FakeProviderOAuthClient(fresh: [.ok("FAKE-bearer-B")])

        let provider = GeminiOAuthProvider(http: http, oauth: oauth)
        let snap = try await provider.fetch(now: now)

        let windows = try #require(snap.quotaWindows)
        #expect(windows.count == 1)
        let pro = windows[0]
        #expect(pro.name == "gemini-2.5-pro")
        // 0.85 vs 0.60 — keep LOWEST remainingFraction (0.60) →
        // utilization = 1 - 0.60 = 0.40.
        #expect(abs((pro.utilization ?? -1) - 0.40) < 1e-9)
    }

    // MARK: - C. Tier failure → quota still populates; tooltip nil

    @Test func tierFailure_quotaSucceeds_tooltipNil() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeProviderHTTPClient()
        http.responses[quotaPath] = [
            .success(try loadFixtureData("gemini-quota-response-fixture.json"))
        ]
        http.responses[tierPath] = [.failure(HTTPError(status: 500))]
        let oauth = FakeProviderOAuthClient(fresh: [.ok("FAKE-bearer-C")])

        let provider = GeminiOAuthProvider(http: http, oauth: oauth)
        let snap = try await provider.fetch(now: now)

        // Quota fully populated.
        #expect(snap.quotaWindows?.count == 3)
        #expect(snap.quota != nil)

        // Tier failed silently — tooltipLabel nil per Pitfall 8.
        #expect(snap.tooltipLabel == nil)
    }

    // MARK: - D. Tier cold-start (currentTier == null) → tooltipLabel nil

    @Test func tierColdStart_tooltipNil() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeProviderHTTPClient()
        http.responses[quotaPath] = [
            .success(try loadFixtureData("gemini-quota-response-fixture.json"))
        ]
        http.responses[tierPath] = [
            .success(try loadFixtureData("gemini-loadcodeassist-coldstart-fixture.json"))
        ]
        let oauth = FakeProviderOAuthClient(fresh: [.ok("FAKE-bearer-D")])

        let provider = GeminiOAuthProvider(http: http, oauth: oauth)
        let snap = try await provider.fetch(now: now)

        #expect(snap.tooltipLabel == nil)
        #expect(snap.quotaWindows?.count == 3)
    }

    // MARK: - E. Tier id mapping — "standard-tier", "legacy-tier", verbatim

    @Test func tierIdMapping_standardTierAndLegacyTierAndUnknown() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        // Standard tier → "Paid".
        do {
            let http = FakeProviderHTTPClient()
            http.responses[quotaPath] = [.success(Data("{}".utf8))]
            let body = #"{"currentTier": {"id": "standard-tier"}, "cloudaicompanionProject": "p"}"#
            http.responses[tierPath] = [.success(Data(body.utf8))]
            let oauth = FakeProviderOAuthClient(fresh: [.ok("FAKE-bearer-E1")])
            let provider = GeminiOAuthProvider(http: http, oauth: oauth)
            let snap = try await provider.fetch(now: now)
            #expect(snap.tooltipLabel == "Paid")
        }

        // Legacy tier → "Legacy".
        do {
            let http = FakeProviderHTTPClient()
            http.responses[quotaPath] = [.success(Data("{}".utf8))]
            let body = #"{"currentTier": {"id": "legacy-tier"}, "cloudaicompanionProject": "p"}"#
            http.responses[tierPath] = [.success(Data(body.utf8))]
            let oauth = FakeProviderOAuthClient(fresh: [.ok("FAKE-bearer-E2")])
            let provider = GeminiOAuthProvider(http: http, oauth: oauth)
            let snap = try await provider.fetch(now: now)
            #expect(snap.tooltipLabel == "Legacy")
        }

        // Future tier → verbatim (lenient).
        do {
            let http = FakeProviderHTTPClient()
            http.responses[quotaPath] = [.success(Data("{}".utf8))]
            let body = #"{"currentTier": {"id": "future-tier-XYZ"}, "cloudaicompanionProject": "p"}"#
            http.responses[tierPath] = [.success(Data(body.utf8))]
            let oauth = FakeProviderOAuthClient(fresh: [.ok("FAKE-bearer-E3")])
            let provider = GeminiOAuthProvider(http: http, oauth: oauth)
            let snap = try await provider.fetch(now: now)
            #expect(snap.tooltipLabel == "future-tier-XYZ")
        }
    }

    // MARK: - F. Lazy 401 retry — quota 401 first, then 200 after retry

    @Test func lazy401_singleShotRetry_succeedsOnSecondCall() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeProviderHTTPClient()
        http.responses[quotaPath] = [
            .failure(HTTPError(status: 401)),
            .success(try loadFixtureData("gemini-quota-response-fixture.json")),
        ]
        http.responses[tierPath] = [
            .success(try loadFixtureData("gemini-loadcodeassist-fixture.json"))
        ]
        let oauth = FakeProviderOAuthClient(
            fresh: [.ok("FAKE-bearer-F-fresh")],
            retry: [.ok("FAKE-bearer-F-retry")]
        )

        let provider = GeminiOAuthProvider(http: http, oauth: oauth)
        let snap = try await provider.fetch(now: now)

        // Second-call response populates the snapshot.
        #expect(snap.quotaWindows?.count == 3)
        let status = await provider.status()
        if case .ok = status { } else {
            Issue.record("Expected .ok after retry, got \(status)")
        }

        // OAuth.retryAfter401 called exactly once.
        let retryCalls = await oauth.retryCallCount
        #expect(retryCalls == 1)
    }

    // MARK: - G. cloudaicompanionProject captured for next poll's quota body

    @Test func projectId_capturedFromTier_propagatedToNextQuotaBody() async throws {
        let now1 = Date(timeIntervalSince1970: 1_780_000_000)
        let now2 = Date(timeIntervalSince1970: 1_780_000_300)

        let http = FakeProviderHTTPClient()
        // First poll — quota success, tier success (project "P-first").
        // Second poll — quota success, tier failure (doesn't matter).
        http.responses[quotaPath] = [
            .success(try loadFixtureData("gemini-quota-response-fixture.json")),
            .success(try loadFixtureData("gemini-quota-response-fixture.json")),
        ]
        let firstTier = #"{"currentTier": {"id": "free-tier"}, "cloudaicompanionProject": "P-first"}"#
        http.responses[tierPath] = [
            .success(Data(firstTier.utf8)),
            .failure(HTTPError(status: 500)),
        ]
        let oauth = FakeProviderOAuthClient(
            fresh: [.ok("FAKE-bearer-G1"), .ok("FAKE-bearer-G2")]
        )

        let provider = GeminiOAuthProvider(http: http, oauth: oauth)
        _ = try await provider.fetch(now: now1)
        _ = try await provider.fetch(now: now2)

        // Second-poll quota body must carry "project": "P-first".
        let body = try #require(http.latestBody(forPath: quotaPath))
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let unwrapped = try #require(json)
        #expect(unwrapped["project"] as? String == "P-first")
    }

    // MARK: - H. Structural concurrent-fetch invariant (async let pair)

    @Test func concurrentFetch_structuralInvariant() throws {
        // Structural assertion (the per-bucket fold is exercised in
        // tests A/B; this test pins the structural shape that
        // satisfies acceptance criterion `grep -n 'async let.*Quota'`
        // and `grep -n 'async let.*Tier'` ≥ 1).
        let repoRoot = repoRootFromTestFile()
        let url = repoRoot
            .appendingPathComponent("AgentsUsageBar/Providers/Gemini/GeminiOAuthProvider.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        #expect(src.range(of: #"async let quotaResult"#) != nil)
        #expect(src.range(of: #"async let tierResult"#) != nil)
    }

    // MARK: - Helpers

    private func repoRootFromTestFile() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("AgentsUsageBar.xcodeproj")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }
}

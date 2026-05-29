import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - FakeLMStudioHTTPClient
//
// NSLock-protected fake HTTPClient for LMStudioProvider tests.
// LMStudioProvider issues sequential probes (v0 → on-failure → v1); NSLock is still
// good hygiene for shared state (Phase 3 STATE #83 pattern).

final class FakeLMStudioHTTPClient: HTTPClient, @unchecked Sendable {

    struct RecordedCall: Sendable {
        let url: URL
        let bearerIsNil: Bool
    }

    private let lock = NSLock()
    private var _responses: [String: [Result<Data, Error>]] = [:]
    private var _calls: [RecordedCall] = []

    var responses: [String: [Result<Data, Error>]] {
        get { lock.withLock { _responses } }
        set { lock.withLock { _responses = newValue } }
    }

    var calls: [RecordedCall] {
        lock.withLock { _calls }
    }

    private func recordCall(_ call: RecordedCall) {
        lock.withLock { _calls.append(call) }
    }

    private func takeResponse(forPath path: String) -> Result<Data, Error>? {
        lock.withLock {
            guard var queue = _responses[path], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            _responses[path] = queue
            return first
        }
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, path: String) throws -> T {
        guard let result = takeResponse(forPath: path) else {
            throw HTTPError(status: 500, message: "FakeLMStudioHTTPClient: no response scripted for \(path)")
        }
        switch result {
        case .success(let data):
            return try JSONDecoder().decode(T.self, from: data)
        case .failure(let err):
            throw err
        }
    }

    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret,
        extraHeaders: [String: String],
        useSnakeCaseConversion: Bool,
        as type: T.Type
    ) async throws -> T {
        recordCall(.init(url: url, bearerIsNil: false))
        return try decodeResponse(type, path: url.path)
    }

    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret?,
        extraHeaders: [String: String],
        useSnakeCaseConversion: Bool,
        as type: T.Type
    ) async throws -> T {
        recordCall(.init(url: url, bearerIsNil: bearer == nil))
        return try decodeResponse(type, path: url.path)
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        throw HTTPError(status: 501, message: "FakeLMStudioHTTPClient: postJSON not scripted")
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        bearer: Secret,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        throw HTTPError(status: 501, message: "FakeLMStudioHTTPClient: postJSON(bearer:) not scripted")
    }

    func postFormURLEncoded<T: Decodable & Sendable>(
        _ url: URL,
        formFields: [(String, String)],
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        throw HTTPError(status: 501, message: "FakeLMStudioHTTPClient: postFormURLEncoded not scripted")
    }
}

// MARK: - Fixture loading

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

// MARK: - URL path helpers (port 1234 default)

private func v0Path(port: Int = 1234) -> String { "/api/v0/models" }
private func v1Path(port: Int = 1234) -> String { "/v1/models" }

// MARK: - LMStudioProviderTests

/// `.serialized` trait — Phase 3 STATE #69 + Phase 2 STATE #19.
@Suite("LMStudioProviderTests", .serialized)
struct LMStudioProviderTests {

    // MARK: - (a) Extended endpoint success — all loaded

    @Test func extendedEndpointSuccess_singleLoadedModel() async throws {
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path()] = [.success(try fixtureData("lmstudio-v0-models-all-loaded.json"))]

        let provider = LMStudioProvider(http: http, port: 1234)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let snap = try await provider.fetch(now: now)

        // All-loaded fixture has meta-llama-3.1-8b first, phi-3-mini second
        #expect(snap.raw["modelName"] == "meta-llama-3.1-8b")
        #expect(snap.raw["modelCount"] == "2")
        #expect(snap.raw["allModels"] == "meta-llama-3.1-8b|phi-3-mini")
        #expect(snap.raw["source"] == "lmstudio")
        #expect(snap.tooltipLabel != nil)
        #expect(snap.tokensToday == nil)
        #expect(snap.costTodayUSD == nil)
        #expect(snap.quota == nil)
        let status = await provider.status()
        if case .ok = status { } else { Issue.record("Expected .ok, got \(status)") }
    }

    // MARK: - (b) Extended endpoint 404 → fallback to v1

    @Test func extendedEndpoint404_fallsBackToV1() async throws {
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path()] = [.failure(HTTPError(status: 404))]
        http.responses[v1Path()] = [.success(try fixtureData("lmstudio-v1-models-fallback.json"))]

        let provider = LMStudioProvider(http: http, port: 1234)
        let snap = try await provider.fetch(now: Date())

        #expect(snap.raw["modelName"] == "meta-llama-3.1-8b")
        #expect(snap.raw["modelCount"] == "1")
        #expect(snap.raw["source"] == "lmstudio")
        let status = await provider.status()
        if case .ok = status { } else { Issue.record("Expected .ok after v1 fallback, got \(status)") }
    }

    // MARK: - (c) HTTP 500 on extended endpoint also triggers fallback (OQ-2)

    @Test func extendedEndpoint500_alsoFallsBack() async throws {
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path()] = [.failure(HTTPError(status: 500))]
        http.responses[v1Path()] = [.success(try fixtureData("lmstudio-v1-models-fallback.json"))]

        let provider = LMStudioProvider(http: http, port: 1234)
        let snap = try await provider.fetch(now: Date())

        // Fallback fired — v1 data present
        #expect(snap.raw["modelName"] == "meta-llama-3.1-8b")
        #expect(snap.raw["source"] == "lmstudio")
    }

    // MARK: - (d) Both endpoints connection refused → .notRunning

    @Test func bothEndpointsConnectionRefused_notRunning() async throws {
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path()] = [.failure(URLError(.cannotConnectToHost))]
        // v1 should NOT be called when primary is URLError

        let provider = LMStudioProvider(http: http, port: 1234)
        // Must NOT throw
        let snap = try await provider.fetch(now: Date())

        let status = await provider.status()
        #expect(status == .notRunning)
        #expect(snap.raw["modelCount"] == "0")
    }

    // MARK: - (e) Timed out → .notRunning

    @Test func bothEndpointsTimedOut_notRunning() async throws {
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path()] = [.failure(URLError(.timedOut))]

        let provider = LMStudioProvider(http: http, port: 1234)
        _ = try await provider.fetch(now: Date())

        let status = await provider.status()
        #expect(status == .notRunning)
    }

    // MARK: - (f) All not-loaded → idle state B

    @Test func extendedSuccessButAllNotLoaded_idleStateB() async throws {
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path()] = [.success(try fixtureData("lmstudio-v0-models-none-loaded.json"))]

        let provider = LMStudioProvider(http: http, port: 1234)
        let snap = try await provider.fetch(now: Date())

        #expect(snap.raw["modelCount"] == "0")
        #expect(snap.raw["installedCount"] == "2")
        let status = await provider.status()
        if case .ok = status { } else { Issue.record("Expected .ok for idle state B, got \(status)") }
    }

    // MARK: - (g) Empty data → idle state B'

    @Test func extendedEmptyData_idleStateBPrime() async throws {
        let http = FakeLMStudioHTTPClient()
        let json = #"{"object":"list","data":[]}"#
        let data = try #require(json.data(using: .utf8))
        http.responses[v0Path()] = [.success(data)]

        let provider = LMStudioProvider(http: http, port: 1234)
        let snap = try await provider.fetch(now: Date())

        #expect(snap.raw["modelCount"] == "0")
        #expect(snap.raw["installedCount"] == "0")
    }

    // MARK: - (h) Port override propagated to probe URLs

    @Test func portOverride_isUsedInProbeURL() async throws {
        let http = FakeLMStudioHTTPClient()
        // Script both endpoints to avoid unscripted-call error
        http.responses["/api/v0/models"] = [.failure(HTTPError(status: 404))]
        http.responses["/v1/models"] = [.failure(URLError(.cannotConnectToHost))]

        let provider = LMStudioProvider(http: http, port: 8765)
        _ = try await provider.fetch(now: Date())

        let allURLs = http.calls.map(\.url.absoluteString)
        #expect(allURLs.contains(where: { $0.contains(":8765/") }))
    }

    // MARK: - (i) Default port 1234 from AppConfig.defaults

    @Test func defaultPort1234_whenComposedFromAppConfigDefaults() async throws {
        let port = AppConfig.defaults.lmstudio.port
        #expect(port == 1234)
        // Constructing with the default port — verify it doesn't crash
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path(port: port)] = [.failure(URLError(.cannotConnectToHost))]
        let provider = LMStudioProvider(http: http, port: port)
        _ = try await provider.fetch(now: Date())
        // If we get here without crash, the default port is correct
    }

    // MARK: - (j) v0 success avoids v1 probe

    @Test func v0SuccessAvoidsV1Probe() async throws {
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path()] = [.success(try fixtureData("lmstudio-v0-models-all-loaded.json"))]
        // Do NOT script /v1/models — if it's called, the fake will throw 500

        let provider = LMStudioProvider(http: http, port: 1234)
        _ = try await provider.fetch(now: Date())

        let v1Calls = http.calls.filter { $0.url.path == "/v1/models" }
        #expect(v1Calls.isEmpty)
    }

    // MARK: - (k) URLError on primary → v1 NOT attempted; URLError on v1 fallback (after HTTP error on v0)

    @Test func connectionRefusedOnExtended_thenFallbackTimedOut() async throws {
        // v0 URLError → notRunning immediately (v1 never fired)
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path()] = [.failure(URLError(.cannotConnectToHost))]
        // v1 is NOT scripted — proves it's never reached

        let provider = LMStudioProvider(http: http, port: 1234)
        _ = try await provider.fetch(now: Date())

        let status = await provider.status()
        #expect(status == .notRunning)

        // Verify v1 was never called
        let v1Calls = http.calls.filter { $0.url.path == "/v1/models" }
        #expect(v1Calls.isEmpty)
    }

    // MARK: - (l) Mixed state — first LOADED model used as modelName

    @Test func mixedState_pickFirstLoadedAsModelName() async throws {
        // mixed-state fixture: qwen2-vl-7b is NOT loaded (first in array), meta-llama-3.1-8b IS loaded
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path()] = [.success(try fixtureData("lmstudio-v0-models-mixed-state.json"))]

        let provider = LMStudioProvider(http: http, port: 1234)
        let snap = try await provider.fetch(now: Date())

        // Only the loaded model should appear
        #expect(snap.raw["modelName"] == "meta-llama-3.1-8b")
        #expect(snap.raw["modelCount"] == "1")
    }

    // MARK: - (m) LOCAL-06 — no token fields ever emitted

    @Test func noTokenFieldEverEmitted() throws {
        let providerSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentsUsageBar/Providers/LMStudio/LMStudioProvider.swift")

        let source = try String(contentsOf: providerSourceURL, encoding: .utf8)
        // Check for actual code patterns (not doc comments or nil assignments)
        #expect(!source.contains("tokensToday: Int("))
        #expect(!source.contains("tokensToday: tokens"))
        #expect(!source.contains("costTodayUSD: Decimal("))
        #expect(!source.contains("tokenCount"))
    }

    // MARK: - (n) D-12 — no CircuitBreaker in provider

    @Test func noCircuitBreakerInProvider() throws {
        let providerSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentsUsageBar/Providers/LMStudio/LMStudioProvider.swift")

        let source = try String(contentsOf: providerSourceURL, encoding: .utf8)
        #expect(!source.contains("CircuitBreaker("))
    }

    // MARK: - (o) SEC-01 — bearer always nil on probe calls

    @Test func bearerAlwaysNilOnProbeCalls() async throws {
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path()] = [.success(try fixtureData("lmstudio-v0-models-all-loaded.json"))]

        let provider = LMStudioProvider(http: http, port: 1234)
        _ = try await provider.fetch(now: Date())

        let nonNilBearerCalls = http.calls.filter { !$0.bearerIsNil }
        #expect(nonNilBearerCalls.isEmpty)
    }

    // MARK: - (p) v1 fallback also URLError on v1 → notRunning

    @Test func v0HttpError_v1ConnectionRefused_yieldsNotRunning() async throws {
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path()] = [.failure(HTTPError(status: 404))]
        http.responses[v1Path()] = [.failure(URLError(.cannotConnectToHost))]

        let provider = LMStudioProvider(http: http, port: 1234)
        _ = try await provider.fetch(now: Date())

        let status = await provider.status()
        #expect(status == .notRunning)
    }

    // MARK: - (q) v1 fallback HTTP 500 → degraded (not notRunning)

    @Test func v0HttpError_v1Http500_yieldsDegraded() async throws {
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path()] = [.failure(HTTPError(status: 404))]
        http.responses[v1Path()] = [.failure(HTTPError(status: 500))]

        let provider = LMStudioProvider(http: http, port: 1234)
        // Must NOT throw
        let snap = try await provider.fetch(now: Date())

        let status = await provider.status()
        switch status {
        case .error, .stale:
            break // expected — server responded but with 5xx
        case .notRunning:
            Issue.record("Expected .error/.stale for HTTP 500 on v1, got .notRunning")
        default:
            Issue.record("Unexpected status \(status)")
        }
        #expect(snap.providerID == .lmstudio)
    }

    // MARK: - (r) providerID and capabilities invariants

    @Test func capabilitiesInvariants() async throws {
        let http = FakeLMStudioHTTPClient()
        let provider = LMStudioProvider(http: http, port: 1234)
        #expect(provider.id == .lmstudio)
        #expect(provider.capabilities.isLocal == true)
        #expect(provider.capabilities.hasTokens == false)
        #expect(provider.capabilities.hasQuota == false)
        #expect(provider.capabilities.hasCost == false)
    }

    // MARK: - (s) Never throws — fetch always returns (no unhandled throw)

    @Test func neverThrowsOnConnectionRefused() async {
        let http = FakeLMStudioHTTPClient()
        http.responses[v0Path()] = [.failure(URLError(.cannotConnectToHost))]
        let provider = LMStudioProvider(http: http, port: 1234)
        // Confirm no throw by using try? and verifying result is non-nil
        let snap = try? await provider.fetch(now: Date())
        #expect(snap != nil)
    }
}

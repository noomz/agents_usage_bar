import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - FakeOllamaHTTPClient
//
// NSLock-protected fake HTTPClient for OllamaProvider tests.
// OllamaProvider issues `async let psResult` and `async let tagsResult` concurrently
// against the same instance — Phase 3 STATE #83 lesson: without serialisation the
// dictionary COW machinery and Array growth produce ~60% flake rate.
// All mutable state gated by `lock`; getters return defensive copies.

final class FakeOllamaHTTPClient: HTTPClient, @unchecked Sendable {

    struct RecordedCall: Sendable {
        let url: URL
        let bearerIsNil: Bool
    }

    private let lock = NSLock()
    private var _responses: [String: [Result<Data, Error>]] = [:]
    private var _calls: [RecordedCall] = []

    // MARK: - Configuration (call under lock or before concurrent access)

    var responses: [String: [Result<Data, Error>]] {
        get { lock.withLock { _responses } }
        set { lock.withLock { _responses = newValue } }
    }

    var calls: [RecordedCall] {
        lock.withLock { _calls }
    }

    // MARK: - Helpers

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
            throw HTTPError(status: 500, message: "FakeOllamaHTTPClient: no response scripted for \(path)")
        }
        switch result {
        case .success(let data):
            return try JSONDecoder().decode(T.self, from: data)
        case .failure(let err):
            throw err
        }
    }

    // MARK: - HTTPClient — GET (bearer: Secret)

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

    // MARK: - HTTPClient — GET (bearer: Secret?)

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

    // MARK: - HTTPClient — POST (stubs — not used by OllamaProvider)

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        throw HTTPError(status: 501, message: "FakeOllamaHTTPClient: postJSON not scripted")
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        bearer: Secret,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        throw HTTPError(status: 501, message: "FakeOllamaHTTPClient: postJSON(bearer:) not scripted")
    }

    func postFormURLEncoded<T: Decodable & Sendable>(
        _ url: URL,
        formFields: [(String, String)],
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        throw HTTPError(status: 501, message: "FakeOllamaHTTPClient: postFormURLEncoded not scripted")
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

// MARK: - Convenience: URL paths

private let psPath = OllamaProvider.psURL.path
private let tagsPath = OllamaProvider.tagsURL.path

// MARK: - OllamaProviderTests

/// `.serialized` trait — Phase 3 STATE #69 + Phase 2 STATE #19.
/// OllamaProvider's concurrent `async let` calls race against the shared
/// `FakeOllamaHTTPClient`; serialised execution eliminates inter-test interference.
@Suite("OllamaProviderTests", .serialized)
struct OllamaProviderTests {

    // MARK: - A. Happy path — single model

    @Test func happyPath_singleModelLoaded() async throws {
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.success(try fixtureData("ollama-ps-single-model.json"))]
        http.responses[tagsPath] = [.success(try fixtureData("ollama-tags-non-empty.json"))]

        let provider = OllamaProvider(http: http)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let snap = try await provider.fetch(now: now)

        #expect(snap.raw["modelName"] == "llama3:8b")
        #expect(snap.raw["modelCount"] == "1")
        #expect(snap.raw["vramBytes"] == "5137025024")
        #expect(snap.raw["source"] == "ollama")
        #expect(snap.tokensToday == nil)
        #expect(snap.costTodayUSD == nil)
        #expect(snap.quota == nil)
        let status = await provider.status()
        if case .ok = status { } else { Issue.record("Expected .ok, got \(status)") }
    }

    // MARK: - B. Multi-model — state D

    @Test func multipleModelsLoaded_stateD() async throws {
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.success(try fixtureData("ollama-ps-multi-model.json"))]
        http.responses[tagsPath] = [.success(try fixtureData("ollama-tags-non-empty.json"))]

        let provider = OllamaProvider(http: http)
        let snap = try await provider.fetch(now: Date())

        // First model name per RESEARCH §5.1 row D
        #expect(snap.raw["modelName"] == "llama3:8b")
        #expect(snap.raw["modelCount"] == "3")
        #expect(snap.raw["allModels"] == "llama3:8b|mistral:7b|phi3:mini")
    }

    // MARK: - C. Idle state B — ps empty, tags non-empty

    @Test func psEmpty_tagsNonEmpty_idleStateB() async throws {
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.success(try fixtureData("ollama-ps-empty.json"))]
        http.responses[tagsPath] = [.success(try fixtureData("ollama-tags-non-empty.json"))]

        let provider = OllamaProvider(http: http)
        let snap = try await provider.fetch(now: Date())

        #expect(snap.raw["modelCount"] == "0")
        #expect(snap.raw["installedCount"] == "2")
        #expect(snap.raw["source"] == "ollama")
    }

    // MARK: - D. Idle state B' — both empty

    @Test func psEmpty_tagsEmpty_idleStateBPrime() async throws {
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.success(try fixtureData("ollama-ps-empty.json"))]
        http.responses[tagsPath] = [.success(try fixtureData("ollama-tags-empty.json"))]

        let provider = OllamaProvider(http: http)
        let snap = try await provider.fetch(now: Date())

        #expect(snap.raw["modelCount"] == "0")
        #expect(snap.raw["installedCount"] == "0")
    }

    // MARK: - E. Connection refused → .notRunning (cannotConnectToHost)

    @Test func connectionRefused_psError_yieldsNotRunning() async throws {
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.failure(URLError(.cannotConnectToHost))]
        http.responses[tagsPath] = [.success(try fixtureData("ollama-tags-non-empty.json"))]

        let provider = OllamaProvider(http: http)
        let snap = try await provider.fetch(now: Date())

        let status = await provider.status()
        #expect(status == .notRunning)
        #expect(snap.raw["modelCount"] == "0")
    }

    // MARK: - F. Timed out → .notRunning

    @Test func connectionRefused_timedOut_yieldsNotRunning() async throws {
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.failure(URLError(.timedOut))]
        http.responses[tagsPath] = [.success(try fixtureData("ollama-tags-empty.json"))]

        let provider = OllamaProvider(http: http)
        _ = try await provider.fetch(now: Date())

        let status = await provider.status()
        #expect(status == .notRunning)
    }

    // MARK: - G. HTTP 500 → degraded / .error (never throws)

    @Test func http500_yieldsErrorState() async throws {
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.failure(HTTPError(status: 500))]
        http.responses[tagsPath] = [.success(try fixtureData("ollama-tags-empty.json"))]

        let provider = OllamaProvider(http: http)
        // Must NOT throw — GEMINI-04 cross-provider isolation.
        let snap = try await provider.fetch(now: Date())

        let status = await provider.status()
        switch status {
        case .error, .stale:
            break // expected
        default:
            Issue.record("Expected .error or .stale for HTTP 500, got \(status)")
        }
        // Snapshot returned (not nil via throw).
        #expect(snap.providerID == .ollama)
    }

    // MARK: - H. Tags failure does not abort ps

    @Test func tagsFailureDoesNotAbortPs() async throws {
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.success(try fixtureData("ollama-ps-single-model.json"))]
        http.responses[tagsPath] = [.failure(HTTPError(status: 503))]

        let provider = OllamaProvider(http: http)
        let snap = try await provider.fetch(now: Date())

        // Snapshot built from /api/ps; tags failure silently ignored (RESEARCH §2.4).
        #expect(snap.raw["modelName"] == "llama3:8b")
        let status = await provider.status()
        if case .ok = status { } else { Issue.record("Expected .ok, got \(status)") }
    }

    // MARK: - I. Lenient decoder swallows unknown top-level fields

    @Test func lenientDecoder_swallowsUnknownPsFields() async throws {
        let json = #"{"models":[],"new_field":42}"#
        let data = try #require(json.data(using: .utf8))
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.success(data)]
        http.responses[tagsPath] = [.success(try fixtureData("ollama-tags-empty.json"))]

        let provider = OllamaProvider(http: http)
        // Must not throw even with unknown top-level key.
        let snap = try await provider.fetch(now: Date())
        #expect(snap.raw["modelCount"] == "0")
    }

    // MARK: - J. Multi-poll: stale snapshot preserved on degraded second poll

    @Test func multiPollCachesLastSnapshot_forDegraded() async throws {
        let http = FakeOllamaHTTPClient()
        // First poll: success
        http.responses[psPath] = [
            .success(try fixtureData("ollama-ps-single-model.json")),
            .failure(HTTPError(status: 500))
        ]
        http.responses[tagsPath] = [
            .success(try fixtureData("ollama-tags-non-empty.json")),
            .success(try fixtureData("ollama-tags-non-empty.json"))
        ]

        let provider = OllamaProvider(http: http)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        _ = try await provider.fetch(now: now)

        // Second poll: /api/ps → HTTP 500 → degraded.
        let snap2 = try await provider.fetch(now: now.addingTimeInterval(300))

        let status = await provider.status()
        switch status {
        case .stale, .error:
            break // expected
        default:
            Issue.record("Expected stale/error on second degraded poll, got \(status)")
        }
        #expect(snap2.raw["source"] == "ollama")
        #expect(snap2.raw["note"] == "degraded")
    }

    // MARK: - K. bearer is always nil (SEC-01)

    @Test func bearer_isAlwaysNil() async throws {
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.success(try fixtureData("ollama-ps-empty.json"))]
        http.responses[tagsPath] = [.success(try fixtureData("ollama-tags-empty.json"))]

        let provider = OllamaProvider(http: http)
        _ = try await provider.fetch(now: Date())

        let allCalls = http.calls
        #expect(!allCalls.isEmpty)
        for call in allCalls {
            #expect(call.bearerIsNil == true,
                    "Expected bearer == nil for all OllamaProvider GET calls (SEC-01). Got bearerIsNil=false for \(call.url)")
        }
    }

    // MARK: - L. LOCAL-06 anti-feature: no token/cost field in OllamaProvider source

    @Test func noTokenFieldEverEmitted() throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentsUsageBar/Providers/Ollama/OllamaProvider.swift")
        let source = try String(contentsOf: sourceFile, encoding: .utf8)
        // LOCAL-06: provider must never assign a non-nil token count or cost.
        // Check for non-nil assignments (not doc comment mentions).
        #expect(!source.contains("tokensToday: Int("), "OllamaProvider must not assign Int tokensToday (LOCAL-06)")
        #expect(!source.contains("tokensToday: tokens"), "OllamaProvider must not assign tokensToday from variable (LOCAL-06)")
        #expect(!source.contains("tokenCount"), "OllamaProvider must not reference tokenCount (LOCAL-06)")
        #expect(!source.contains("tokensPerSecond"), "OllamaProvider must not reference tokensPerSecond (LOCAL-06)")
        // Verify no non-nil cost assignment via Decimal()
        #expect(!source.contains("costTodayUSD: Decimal("), "OllamaProvider must not compute cost (LOCAL-06)")
    }

    // MARK: - M. D-12: no CircuitBreaker instantiation

    @Test func noCircuitBreaker_d12Invariant() throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentsUsageBar/Providers/Ollama/OllamaProvider.swift")
        let source = try String(contentsOf: sourceFile, encoding: .utf8)
        #expect(!source.contains("CircuitBreaker("), "OllamaProvider must not instantiate CircuitBreaker (D-12)")
    }

    // MARK: - N. Tooltip for single model with full details

    @Test func singleModel_tooltipContainsDetails() async throws {
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.success(try fixtureData("ollama-ps-single-model.json"))]
        http.responses[tagsPath] = [.success(try fixtureData("ollama-tags-non-empty.json"))]

        let provider = OllamaProvider(http: http)
        let snap = try await provider.fetch(now: Date())

        // Tooltip should contain "llama · 8.0B · Q4_0"
        let tooltip = try #require(snap.tooltipLabel)
        #expect(tooltip.contains("llama"))
        #expect(tooltip.contains("8.0B"))
        #expect(tooltip.contains("Q4_0"))
    }

    // MARK: - O. Multi-model tooltip: all model names one per line

    @Test func multiModel_tooltipEnumeratesAllModels() async throws {
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.success(try fixtureData("ollama-ps-multi-model.json"))]
        http.responses[tagsPath] = [.success(try fixtureData("ollama-tags-non-empty.json"))]

        let provider = OllamaProvider(http: http)
        let snap = try await provider.fetch(now: Date())

        let tooltip = try #require(snap.tooltipLabel)
        #expect(tooltip.contains("llama3:8b"))
        #expect(tooltip.contains("mistral:7b"))
        #expect(tooltip.contains("phi3:mini"))
    }

    // MARK: - P. cannotFindHost also yields .notRunning

    @Test func cannotFindHost_yieldsNotRunning() async throws {
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.failure(URLError(.cannotFindHost))]
        http.responses[tagsPath] = [.success(try fixtureData("ollama-tags-empty.json"))]

        let provider = OllamaProvider(http: http)
        _ = try await provider.fetch(now: Date())

        let status = await provider.status()
        #expect(status == .notRunning)
    }

    // MARK: - Q. networkConnectionLost also yields .notRunning

    @Test func networkConnectionLost_yieldsNotRunning() async throws {
        let http = FakeOllamaHTTPClient()
        http.responses[psPath] = [.failure(URLError(.networkConnectionLost))]
        http.responses[tagsPath] = [.success(try fixtureData("ollama-tags-empty.json"))]

        let provider = OllamaProvider(http: http)
        _ = try await provider.fetch(now: Date())

        let status = await provider.status()
        #expect(status == .notRunning)
    }

    // MARK: - R. Capabilities correct (isLocal:true, hasTokens:false)

    @Test func capabilities_isLocalTrueHasTokensFalse() {
        let provider = OllamaProvider(http: FakeOllamaHTTPClient())
        #expect(provider.capabilities.isLocal == true)
        #expect(provider.capabilities.hasTokens == false)
        #expect(provider.capabilities.hasQuota == false)
        #expect(provider.capabilities.hasCost == false)
    }
}

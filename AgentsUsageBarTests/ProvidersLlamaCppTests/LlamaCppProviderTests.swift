import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - FakeLlamaCppHTTPClient
//
// NSLock-protected fake HTTPClient for LlamaCppProvider tests.
// LlamaCppProvider issues concurrent probes (/health + /v1/models via async let),
// plus an opportunistic /slots probe. NSLock ensures thread-safe access to shared state
// (Phase 3 STATE #83 pattern).

final class FakeLlamaCppHTTPClient: HTTPClient, @unchecked Sendable {

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
            throw HTTPError(status: 500, message: "FakeLlamaCppHTTPClient: no response scripted for \(path)")
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
        recordCall(RecordedCall(url: url, bearerIsNil: false))
        return try decodeResponse(T.self, path: url.path)
    }

    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret?,
        extraHeaders: [String: String],
        useSnakeCaseConversion: Bool,
        as type: T.Type
    ) async throws -> T {
        recordCall(RecordedCall(url: url, bearerIsNil: bearer == nil))
        return try decodeResponse(T.self, path: url.path)
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        throw HTTPError(status: 501, message: "FakeLlamaCppHTTPClient: postJSON not scripted")
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        bearer: Secret,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        throw HTTPError(status: 501, message: "FakeLlamaCppHTTPClient: postJSON(bearer:) not scripted")
    }

    func postFormURLEncoded<T: Decodable & Sendable>(
        _ url: URL,
        formFields: [(String, String)],
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        throw HTTPError(status: 501, message: "FakeLlamaCppHTTPClient: postFormURLEncoded not scripted")
    }
}

// MARK: - Fixture helpers

private func llamaCppProviderFixture(_ name: String) -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    return (try? Data(contentsOf: url)) ?? Data()
}

// MARK: - LlamaCppProviderTests

@Suite("LlamaCppProviderTests", .serialized)
struct LlamaCppProviderTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let port = 8080

    private func makeProvider(http: FakeLlamaCppHTTPClient, port: Int = 8080) -> LlamaCppProvider {
        LlamaCppProvider(http: http, clock: SystemClock(), port: port)
    }

    // MARK: - Happy path

    @Test func happyPath_okHealthAndModel() async throws {
        let http = FakeLlamaCppHTTPClient()
        http.responses = [
            "/health": [.success(llamaCppProviderFixture("llamacpp-health-ok.json"))],
            "/v1/models": [.success(llamaCppProviderFixture("llamacpp-v1-models.json"))],
            "/slots": [.success(llamaCppProviderFixture("llamacpp-slots.json"))]
        ]
        let provider = makeProvider(http: http)
        let snap = try await provider.fetch(now: now)

        #expect(snap.raw["modelName"] == "llama-3-8b-instruct-Q4_K_M.gguf")
        #expect(snap.raw["modelCount"] == "1")
        #expect(snap.raw["loadingModel"] != "true")
        let st = await provider.status()
        if case .ok = st { } else { Issue.record("Expected .ok, got \(st)") }
    }

    // MARK: - State E

    @Test func loadingModelHealth_yieldsStateE() async throws {
        let http = FakeLlamaCppHTTPClient()
        http.responses = [
            "/health": [.success(llamaCppProviderFixture("llamacpp-health-loading.json"))],
            "/v1/models": [.failure(URLError(.cannotConnectToHost))]
        ]
        let provider = makeProvider(http: http)
        let snap = try await provider.fetch(now: now)

        // State E: loadingModel="true", modelCount="0"
        #expect(snap.raw["loadingModel"] == "true")
        #expect(snap.raw["modelCount"] == "0")
        // State E is a sub-state of .ok — NOT .error (RESEARCH §5.1)
        let st = await provider.status()
        if case .ok = st { } else { Issue.record("State E must be .ok sub-state, got \(st)") }
    }

    // MARK: - Error health

    @Test func errorHealth_yieldsErrorStatus() async throws {
        let http = FakeLlamaCppHTTPClient()
        http.responses = [
            "/health": [.success(llamaCppProviderFixture("llamacpp-health-error.json"))],
            "/v1/models": [.failure(URLError(.cannotConnectToHost))]
        ]
        let provider = makeProvider(http: http)
        let snap = try await provider.fetch(now: now)

        // Must return a snapshot (never throws) and status must be .error or .stale
        #expect(snap.providerID == .llamacpp)
        let st = await provider.status()
        switch st {
        case .error, .stale: break
        default: Issue.record("Expected .error or .stale for health='error', got \(st)")
        }
    }

    // MARK: - No-slot still running

    @Test func noSlotHealth_stillTreatedAsRunning() async throws {
        let http = FakeLlamaCppHTTPClient()
        http.responses = [
            "/health": [.success(llamaCppProviderFixture("llamacpp-health-no-slot.json"))],
            "/v1/models": [.success(llamaCppProviderFixture("llamacpp-v1-models.json"))],
            "/slots": [.failure(URLError(.cannotConnectToHost))]
        ]
        let provider = makeProvider(http: http)
        let snap = try await provider.fetch(now: now)

        // "no slot available" → server running; model name still populated
        let st = await provider.status()
        if case .ok = st { } else { Issue.record("Expected .ok for no-slot health, got \(st)") }
        #expect(snap.raw["modelName"] == "llama-3-8b-instruct-Q4_K_M.gguf")
    }

    // MARK: - Connection refused

    @Test func connectionRefused_health_yieldsNotRunning() async throws {
        let http = FakeLlamaCppHTTPClient()
        http.responses = [
            "/health": [.failure(URLError(.cannotConnectToHost))],
            "/v1/models": [.failure(URLError(.cannotConnectToHost))]
        ]
        let provider = makeProvider(http: http)
        let snap = try await provider.fetch(now: now)

        #expect(snap.raw["modelCount"] == "0")
        let st = await provider.status()
        if case .notRunning = st { } else { Issue.record("Expected .notRunning for connection refused, got \(st)") }
    }

    @Test func timedOut_yieldsNotRunning() async throws {
        let http = FakeLlamaCppHTTPClient()
        http.responses = [
            "/health": [.failure(URLError(.timedOut))],
            "/v1/models": [.failure(URLError(.timedOut))]
        ]
        let provider = makeProvider(http: http)
        _ = try await provider.fetch(now: now)

        let st = await provider.status()
        if case .notRunning = st { } else { Issue.record("Expected .notRunning for timedOut, got \(st)") }
    }

    // MARK: - Models failure does not abort health

    @Test func modelsFailureDoesNotAbortHealth() async throws {
        let http = FakeLlamaCppHTTPClient()
        http.responses = [
            "/health": [.success(llamaCppProviderFixture("llamacpp-health-ok.json"))],
            "/v1/models": [.failure(HTTPError(status: 500, message: "server error"))],
            "/slots": [.failure(URLError(.cannotConnectToHost))]
        ]
        let provider = makeProvider(http: http)
        let snap = try await provider.fetch(now: now)

        let st = await provider.status()
        if case .ok = st { } else { Issue.record("Expected .ok when /v1/models fails but /health ok, got \(st)") }
        #expect(snap.raw["modelCount"] == "0")
        #expect(snap.raw["modelName"] == nil)
    }

    // MARK: - Slots failure is ignored

    @Test func slotsFailureIsIgnored() async throws {
        let http = FakeLlamaCppHTTPClient()
        http.responses = [
            "/health": [.success(llamaCppProviderFixture("llamacpp-health-ok.json"))],
            "/v1/models": [.success(llamaCppProviderFixture("llamacpp-v1-models.json"))],
            "/slots": [.failure(URLError(.cannotConnectToHost))]
        ]
        let provider = makeProvider(http: http)
        let snap = try await provider.fetch(now: now)

        // Snapshot still built; /slots failure silently ignored
        let st = await provider.status()
        if case .ok = st { } else { Issue.record("Expected .ok when /slots fails, got \(st)") }
        #expect(snap.raw["modelName"] == "llama-3-8b-instruct-Q4_K_M.gguf")
    }

    // MARK: - OQ-3 lenient unknown status

    @Test func unknownHealthStatus_lenientAsOK() async throws {
        let json = #"{"status":"future-shape-2027"}"#
        let data = json.data(using: .utf8)!
        let http = FakeLlamaCppHTTPClient()
        http.responses = [
            "/health": [.success(data)],
            "/v1/models": [.success(llamaCppProviderFixture("llamacpp-v1-models.json"))],
            "/slots": [.failure(URLError(.cannotConnectToHost))]
        ]
        let provider = makeProvider(http: http)
        let snap = try await provider.fetch(now: now)

        // OQ-3: unknown status → treated as .ok
        let st = await provider.status()
        if case .ok = st { } else { Issue.record("OQ-3: unknown health status must map to .ok, got \(st)") }
        #expect(snap.raw["modelName"] == "llama-3-8b-instruct-Q4_K_M.gguf")
    }

    // MARK: - Port is used in probe URLs

    @Test func portIsUsedInProbeURL() async throws {
        let http = FakeLlamaCppHTTPClient()
        http.responses = [
            "/health": [.failure(URLError(.cannotConnectToHost))],
            "/v1/models": [.failure(URLError(.cannotConnectToHost))]
        ]
        let provider = makeProvider(http: http, port: 9999)
        _ = try await provider.fetch(now: now)

        let urlStrings = http.calls.map { $0.url.absoluteString }
        for urlStr in urlStrings {
            #expect(urlStr.contains(":9999/"))
        }
    }

    // MARK: - Basename trimming

    @Test func basenameTrimming_apiURL() async throws {
        let json = #"{"object":"list","data":[{"id":"/foo/bar/baz.gguf"}]}"#
        let data = json.data(using: .utf8)!
        let http = FakeLlamaCppHTTPClient()
        http.responses = [
            "/health": [.success(llamaCppProviderFixture("llamacpp-health-ok.json"))],
            "/v1/models": [.success(data)],
            "/slots": [.failure(URLError(.cannotConnectToHost))]
        ]
        let provider = makeProvider(http: http)
        let snap = try await provider.fetch(now: now)

        #expect(snap.raw["modelName"] == "baz.gguf")
    }

    // MARK: - Last snapshot preserved across degraded poll

    @Test func lastSnapshotPreserved_acrossDegradedPoll() async throws {
        let http = FakeLlamaCppHTTPClient()
        // First poll succeeds
        http.responses = [
            "/health": [
                .success(llamaCppProviderFixture("llamacpp-health-ok.json")),
                .failure(HTTPError(status: 500, message: "server error"))
            ],
            "/v1/models": [
                .success(llamaCppProviderFixture("llamacpp-v1-models.json")),
                .failure(HTTPError(status: 500, message: "server error"))
            ],
            "/slots": [
                .failure(URLError(.cannotConnectToHost)),
                .failure(URLError(.cannotConnectToHost))
            ]
        ]
        let provider = makeProvider(http: http)
        _ = try await provider.fetch(now: now)

        // Second poll: /health returns 500 → degraded
        let now2 = now.addingTimeInterval(300)
        let snap2 = try await provider.fetch(now: now2)

        // Degraded snapshot should preserve prior raw data + note="degraded"
        let st = await provider.status()
        #expect(snap2.raw["note"] == "degraded")
        switch st {
        case .stale, .error: break
        default: Issue.record("Expected .stale or .error on degraded second poll, got \(st)")
        }
    }

    // MARK: - LOCAL-06 source-grep invariant

    @Test func noTokenFieldEverEmitted() throws {
        let providerSource = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentsUsageBar")
            .appendingPathComponent("Providers")
            .appendingPathComponent("LlamaCpp")
            .appendingPathComponent("LlamaCppProvider.swift"))
        // Must not assign actual values (nil assignments are OK — that's the anti-feature enforcement)
        #expect(!providerSource.contains("tokensToday: Int("))
        #expect(!providerSource.contains("tokensToday: tokens"))
        #expect(!providerSource.contains("costTodayUSD: Decimal("))
    }

    // MARK: - D-12 no CircuitBreaker invariant

    @Test func noCircuitBreaker() throws {
        let providerSource = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentsUsageBar")
            .appendingPathComponent("Providers")
            .appendingPathComponent("LlamaCpp")
            .appendingPathComponent("LlamaCppProvider.swift"))
        #expect(!providerSource.contains("CircuitBreaker("))
    }

    // MARK: - SEC-01 bearer always nil

    @Test func bearerAlwaysNil() async throws {
        let http = FakeLlamaCppHTTPClient()
        http.responses = [
            "/health": [.success(llamaCppProviderFixture("llamacpp-health-ok.json"))],
            "/v1/models": [.success(llamaCppProviderFixture("llamacpp-v1-models.json"))],
            "/slots": [.success(llamaCppProviderFixture("llamacpp-slots.json"))]
        ]
        let provider = makeProvider(http: http)
        _ = try await provider.fetch(now: now)

        let calls = http.calls
        #expect(calls.count >= 3)
        for call in calls {
            #expect(call.bearerIsNil == true)
        }
    }

    // MARK: - Capabilities invariants

    @Test func capabilitiesAreLocal() {
        let http = FakeLlamaCppHTTPClient()
        let provider = makeProvider(http: http)
        #expect(provider.capabilities.isLocal == true)
        #expect(provider.capabilities.hasTokens == false)
        #expect(provider.capabilities.hasCost == false)
        #expect(provider.capabilities.hasQuota == false)
    }

    // MARK: - Never throws

    @Test func neverThrows() async {
        let http = FakeLlamaCppHTTPClient()
        // No responses scripted → will throw HTTPError(500) from fake client
        http.responses = [:]
        let provider = makeProvider(http: http)
        // fetch must not propagate an error
        do {
            _ = try await provider.fetch(now: now)
        } catch {
            Issue.record("LlamaCppProvider.fetch must never throw, but got: \(error)")
        }
    }
}

import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - FakeHTTPClient

/// Controllable test double for `HTTPClient`.
/// Captures requests and returns scripted responses for both GET and POST.
final class FakeHTTPClient: HTTPClient, @unchecked Sendable {

    struct Call {
        let url: URL
        let method: String
        let bearer: Secret?
        let extraHeaders: [String: String]
    }

    var calls: [Call] = []
    var getResponses: [Result<Data, Error>] = []
    var postResponses: [Result<Data, Error>] = []

    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        calls.append(Call(url: url, method: "GET", bearer: bearer, extraHeaders: extraHeaders))
        return try decode(type, from: &getResponses)
    }

    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret?,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        calls.append(Call(url: url, method: "GET", bearer: bearer, extraHeaders: extraHeaders))
        return try decode(type, from: &getResponses)
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        // Capture the encoded body bytes for assertion by callers
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let bodyData = try encoder.encode(body)
        capturedPostBodyData = bodyData
        calls.append(Call(url: url, method: "POST", bearer: nil, extraHeaders: extraHeaders))
        return try decode(type, from: &postResponses)
    }

    func postFormURLEncoded<T: Decodable & Sendable>(
        _ url: URL,
        formFields: [(String, String)],
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        // Not exercised by ClaudeOAuthClientTests; this conformance keeps
        // the FakeHTTPClient compilable now that HTTPClient adds a new
        // requirement (Plan 03-05).
        let encoded = formFields
            .map { key, value -> String in
                let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(key)=\(v)"
            }
            .joined(separator: "&")
        capturedPostBodyData = encoded.data(using: .utf8)
        calls.append(Call(url: url, method: "POST", bearer: nil, extraHeaders: extraHeaders))
        return try decode(type, from: &postResponses)
    }

    /// Raw encoded POST body from the most recent postJSON call.
    var capturedPostBodyData: Data?

    private func decode<T: Decodable>(_ type: T.Type, from queue: inout [Result<Data, Error>]) throws -> T {
        guard !queue.isEmpty else {
            throw HTTPError(status: 500, message: "FakeHTTPClient: no response scripted")
        }
        let result = queue.removeFirst()
        switch result {
        case .success(let data):
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        case .failure(let err):
            throw err
        }
    }
}

// MARK: - FakeCredentialResolver

/// Controllable test double for `ClaudeCredentialResolver`.
final class FakeCredentialResolver: ClaudeCredentialResolver, @unchecked Sendable {
    var loadResult: ClaudeCredentialLoader.Result?
    var needsRefreshResult: Bool = false
    var savedCalls: [(ClaudeCredentialLoader.OAuth, ClaudeCredentialLoader.Source)] = []

    func loadCredentials() -> ClaudeCredentialLoader.Result? { loadResult }

    func needsRefresh(
        _ o: ClaudeCredentialLoader.OAuth,
        now: Date,
        refreshBufferMs: Double
    ) -> Bool { needsRefreshResult }

    func saveCredentials(
        _ oauth: ClaudeCredentialLoader.OAuth,
        to source: ClaudeCredentialLoader.Source
    ) throws {
        savedCalls.append((oauth, source))
    }
}

// MARK: - Fixture helpers

private func loadFixtureData(named name: String) throws -> Data {
    let thisFile = URL(fileURLWithPath: #filePath)
    return try Data(contentsOf: thisFile
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name))
}

private func makeOAuth(
    accessToken: String = "fake-access",
    refreshToken: String? = "fake-refresh",
    expiresAt: Double? = nil,
    subscriptionType: String? = "claude_max"
) -> ClaudeCredentialLoader.OAuth {
    .init(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAt: expiresAt,
        subscriptionType: subscriptionType
    )
}

private func makeResult(
    oauth: ClaudeCredentialLoader.OAuth,
    source: ClaudeCredentialLoader.Source = .file
) -> ClaudeCredentialLoader.Result {
    .init(oauth: oauth, source: source)
}

// MARK: - ClaudeOAuthClientTests

@Suite("ClaudeOAuthClientTests", .serialized)
struct ClaudeOAuthClientTests {

    // MARK: - Test 1: noCredentials

    @Test func getUsage_noCredentials_throwsNoCredentials() async throws {
        let http = FakeHTTPClient()
        let creds = FakeCredentialResolver()
        creds.loadResult = nil

        let client = ClaudeOAuthClient(http: http, credentials: creds)
        await #expect(throws: ClaudeOAuthError.noCredentials) {
            _ = try await client.getUsage()
        }
    }

    // MARK: - Test 2: fresh token — skip refresh

    @Test func getUsage_freshToken_skipsRefresh_andCallsHttp() async throws {
        let http = FakeHTTPClient()
        let usageData = try loadFixtureData(named: "oauth-usage-success.json")
        http.getResponses = [.success(usageData)]

        let creds = FakeCredentialResolver()
        let oneHourFuture = (Date().timeIntervalSince1970 + 3600) * 1000
        creds.loadResult = makeResult(oauth: makeOAuth(expiresAt: oneHourFuture))
        creds.needsRefreshResult = false

        let client = ClaudeOAuthClient(http: http, credentials: creds)
        let response = try await client.getUsage()

        #expect(response.fiveHour?.utilization == 67.5)
        // Exactly 1 GET call, 0 POST calls
        #expect(http.calls.count == 1)
        #expect(http.calls[0].method == "GET")
        #expect(creds.savedCalls.isEmpty)
    }

    // MARK: - Test 3: expired token — refresh then usage, saves rotated tokens

    @Test func getUsage_expiredToken_callsRefreshThenUsage_andSaves() async throws {
        let http = FakeHTTPClient()
        let refreshData = try loadFixtureData(named: "oauth-refresh-success.json")
        let usageData = try loadFixtureData(named: "oauth-usage-success.json")
        http.postResponses = [.success(refreshData)]
        http.getResponses = [.success(usageData)]

        let creds = FakeCredentialResolver()
        creds.loadResult = makeResult(oauth: makeOAuth(expiresAt: 0), source: .file)
        creds.needsRefreshResult = true

        let client = ClaudeOAuthClient(http: http, credentials: creds)
        let response = try await client.getUsage()

        #expect(response.fiveHour?.utilization == 67.5)
        // POST then GET
        #expect(http.calls.count == 2)
        #expect(http.calls[0].method == "POST")
        #expect(http.calls[1].method == "GET")
        // Rotated access token saved
        #expect(creds.savedCalls.count == 1)
        #expect(creds.savedCalls[0].0.accessToken == "fake-rotated-access-token-XXXX")
        #expect(creds.savedCalls[0].1 == .file)
    }

    // MARK: - Test 4: refresh fails

    @Test func getUsage_refreshFailed_throwsRefreshFailed() async throws {
        let http = FakeHTTPClient()
        http.postResponses = [.failure(HTTPError(status: 400))]

        let creds = FakeCredentialResolver()
        creds.loadResult = makeResult(oauth: makeOAuth(expiresAt: 0))
        creds.needsRefreshResult = true

        let client = ClaudeOAuthClient(http: http, credentials: creds)
        await #expect(throws: (any Error).self) {
            _ = try await client.getUsage()
        }
    }

    // MARK: - Test 5: 429 surfaces as distinct error (Pitfall 5)

    @Test func getUsage_usageEndpoint429_throws_usageEndpointFailed_429() async throws {
        let http = FakeHTTPClient()
        http.getResponses = [.failure(HTTPError(status: 429))]

        let creds = FakeCredentialResolver()
        creds.loadResult = makeResult(oauth: makeOAuth(refreshToken: nil, expiresAt: nil))
        creds.needsRefreshResult = false

        let client = ClaudeOAuthClient(http: http, credentials: creds)
        await #expect(throws: ClaudeOAuthError.usageEndpointFailed(status: 429)) {
            _ = try await client.getUsage()
        }
    }

    // MARK: - Test 6: generic 5xx

    @Test func getUsage_usageEndpoint500_throws_usageEndpointFailed_500() async throws {
        let http = FakeHTTPClient()
        http.getResponses = [.failure(HTTPError(status: 500))]

        let creds = FakeCredentialResolver()
        creds.loadResult = makeResult(oauth: makeOAuth(refreshToken: nil, expiresAt: nil))
        creds.needsRefreshResult = false

        let client = ClaudeOAuthClient(http: http, credentials: creds)
        await #expect(throws: ClaudeOAuthError.usageEndpointFailed(status: 500)) {
            _ = try await client.getUsage()
        }
    }

    // MARK: - Test 7: anthropic-beta header sent

    @Test func getUsage_sendsAnthropicBetaHeader() async throws {
        let http = FakeHTTPClient()
        let usageData = try loadFixtureData(named: "oauth-usage-success.json")
        http.getResponses = [.success(usageData)]

        let creds = FakeCredentialResolver()
        creds.loadResult = makeResult(oauth: makeOAuth(refreshToken: nil, expiresAt: nil))
        creds.needsRefreshResult = false

        let client = ClaudeOAuthClient(http: http, credentials: creds)
        _ = try await client.getUsage()

        let getCall = try #require(http.calls.first(where: { $0.method == "GET" }))
        #expect(getCall.extraHeaders["anthropic-beta"] == "oauth-2025-04-20")
    }

    // MARK: - Test 8: bearer wraps access token as Secret (redacted)

    @Test func getUsage_sendsBearerWithAccessToken() async throws {
        let http = FakeHTTPClient()
        let usageData = try loadFixtureData(named: "oauth-usage-success.json")
        http.getResponses = [.success(usageData)]

        let creds = FakeCredentialResolver()
        creds.loadResult = makeResult(oauth: makeOAuth(refreshToken: nil, expiresAt: nil))
        creds.needsRefreshResult = false

        let client = ClaudeOAuthClient(http: http, credentials: creds)
        _ = try await client.getUsage()

        let getCall = try #require(http.calls.first(where: { $0.method == "GET" }))
        // SEC-01: bearer must be wrapped in Secret — description is always "<redacted>"
        let bearer = try #require(getCall.bearer)
        #expect(String(describing: bearer) == "<redacted>")
        // Exactly 1 GET call to the usage URL
        #expect(http.calls.count == 1)
        #expect(getCall.url == ClaudeOAuthClient.usageURL)
    }

    // MARK: - Test 9: refresh sends correct body

    @Test func refreshAccessToken_sendsCorrectBody() async throws {
        let http = FakeHTTPClient()
        let refreshData = try loadFixtureData(named: "oauth-refresh-success.json")
        let usageData = try loadFixtureData(named: "oauth-usage-success.json")
        http.postResponses = [.success(refreshData)]
        http.getResponses = [.success(usageData)]

        let creds = FakeCredentialResolver()
        creds.loadResult = makeResult(oauth: makeOAuth(
            accessToken: "old-access",
            refreshToken: "my-refresh-token",
            expiresAt: 0
        ))
        creds.needsRefreshResult = true

        let client = ClaudeOAuthClient(http: http, credentials: creds)
        _ = try await client.getUsage()

        // Decode captured POST body
        let bodyData = try #require(http.capturedPostBodyData)
        let body = try #require(try? JSONSerialization.jsonObject(with: bodyData) as? [String: String])
        #expect(body["grant_type"] == "refresh_token")
        #expect(body["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(body["refresh_token"] == "my-refresh-token")

        // POST went to refresh URL
        let postCall = try #require(http.calls.first(where: { $0.method == "POST" }))
        #expect(postCall.url == ClaudeOAuthClient.refreshURL)
    }

    // MARK: - Test 10: env-source token with nil refreshToken skips refresh

    @Test func getUsage_envSourceToken_skipsRefresh_evenIfExpiresAtNil() async throws {
        let http = FakeHTTPClient()
        let usageData = try loadFixtureData(named: "oauth-usage-success.json")
        http.getResponses = [.success(usageData)]

        let creds = FakeCredentialResolver()
        // env-source token: no refreshToken, nil expiresAt
        let envOAuth = makeOAuth(
            accessToken: "env-token",
            refreshToken: nil,  // no refresh token → branch skipped
            expiresAt: nil
        )
        creds.loadResult = makeResult(oauth: envOAuth, source: .environment)
        creds.needsRefreshResult = true  // would refresh if token existed

        let client = ClaudeOAuthClient(http: http, credentials: creds)
        _ = try await client.getUsage()

        // Only the GET — no POST (no refresh token available)
        #expect(http.calls.count == 1)
        #expect(http.calls[0].method == "GET")
        // saveCredentials NOT called
        #expect(creds.savedCalls.isEmpty)
    }

    // MARK: - Test 11: invalid_client 400 surfaces clear hint

    @Test func getUsage_invalidClient_refresh_surfaces_clear_hint() async throws {
        let http = FakeHTTPClient()
        http.postResponses = [.failure(HTTPError(status: 400))]

        let creds = FakeCredentialResolver()
        creds.loadResult = makeResult(oauth: makeOAuth(expiresAt: 0))
        creds.needsRefreshResult = true

        let client = ClaudeOAuthClient(http: http, credentials: creds)
        do {
            _ = try await client.getUsage()
            Issue.record("Expected refreshFailed error")
        } catch ClaudeOAuthError.refreshFailed(let message) {
            #expect(message.contains("invalid_client"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Test 12: keychain source — save to keychain

    @Test func getUsage_after_refresh_persistsRotatedTokens_to_keychainSource() async throws {
        let http = FakeHTTPClient()
        let refreshData = try loadFixtureData(named: "oauth-refresh-success.json")
        let usageData = try loadFixtureData(named: "oauth-usage-success.json")
        http.postResponses = [.success(refreshData)]
        http.getResponses = [.success(usageData)]

        let creds = FakeCredentialResolver()
        creds.loadResult = makeResult(oauth: makeOAuth(expiresAt: 0), source: .keychain)
        creds.needsRefreshResult = true

        let client = ClaudeOAuthClient(http: http, credentials: creds)
        _ = try await client.getUsage()

        #expect(creds.savedCalls.count == 1)
        #expect(creds.savedCalls[0].1 == .keychain)
        #expect(creds.savedCalls[0].0.accessToken == "fake-rotated-access-token-XXXX")
    }
}

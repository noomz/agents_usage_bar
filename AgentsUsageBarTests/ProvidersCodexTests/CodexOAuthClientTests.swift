import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Fixture helpers

private func loadFixtureData(named name: String) throws -> Data {
    let thisFile = URL(fileURLWithPath: #filePath)
    return try Data(contentsOf: thisFile
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name))
}

private func makeTempAuthFile(content: Data) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test-codex-oauth-\(UUID().uuidString).json")
    try content.write(to: url)
    return url
}

// MARK: - FakeCodexHTTPClient
//
// Mirrors ClaudeOAuthClientTests' FakeHTTPClient pattern (the Phase 2 repo
// convention). Captures requests + scripts responses; satisfies the intent of
// "URLProtocol stub pattern" (STATE #19) at the HTTPClient protocol seam — the
// same level at which CodexOAuthClient is composed. Tests assert on captured
// request URL + bearer + extraHeaders, which is exactly what URLProtocol
// inspection would expose, with less boilerplate.

final class FakeCodexHTTPClient: HTTPClient, @unchecked Sendable {

    struct Call {
        let url: URL
        let method: String
        let bearer: Secret?
        let extraHeaders: [String: String]
    }

    var calls: [Call] = []
    var getResponses: [Result<Data, Error>] = []

    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret,
        extraHeaders: [String: String],
        useSnakeCaseConversion: Bool,
        as type: T.Type
    ) async throws -> T {
        calls.append(Call(url: url, method: "GET", bearer: bearer, extraHeaders: extraHeaders))
        return try decode(type, useSnakeCaseConversion: useSnakeCaseConversion)
    }

    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret?,
        extraHeaders: [String: String],
        useSnakeCaseConversion: Bool,
        as type: T.Type
    ) async throws -> T {
        calls.append(Call(url: url, method: "GET", bearer: bearer, extraHeaders: extraHeaders))
        return try decode(type, useSnakeCaseConversion: useSnakeCaseConversion)
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        // Codex OAuth fallback never posts — but conform to the protocol anyway.
        calls.append(Call(url: url, method: "POST", bearer: nil, extraHeaders: extraHeaders))
        return try decode(type)
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        bearer: Secret,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        // Plan 03-06 protocol widening — Codex tests don't exercise the
        // bearer-authenticated postJSON path; stub conformance only.
        calls.append(Call(url: url, method: "POST", bearer: bearer, extraHeaders: extraHeaders))
        return try decode(type)
    }

    func postFormURLEncoded<T: Decodable & Sendable>(
        _ url: URL,
        formFields: [(String, String)],
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        // Codex never posts a form — the conformance exists solely so the
        // type still satisfies HTTPClient after Plan 03-05 widened the
        // protocol surface.
        calls.append(Call(url: url, method: "POST", bearer: nil, extraHeaders: extraHeaders))
        return try decode(type)
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        useSnakeCaseConversion: Bool = false
    ) throws -> T {
        guard !getResponses.isEmpty else {
            throw HTTPError(status: 500, message: "FakeCodexHTTPClient: no response scripted")
        }
        switch getResponses.removeFirst() {
        case .success(let data):
            let decoder = JSONDecoder()
            if useSnakeCaseConversion {
                decoder.keyDecodingStrategy = .convertFromSnakeCase
            }
            return try decoder.decode(T.self, from: data)
        case .failure(let err):
            throw err
        }
    }
}

// MARK: - CodexOAuthClientTests

@Suite("CodexOAuthClientTests", .serialized)
struct CodexOAuthClientTests {

    // MARK: - 1. Happy path — request shape (URL + bearer + ChatGPT-Account-Id)

    @Test func happyPath_sendsBearer_andAccountIdHeader_andReturnsDecoded() async throws {
        let http = FakeCodexHTTPClient()
        let body = try loadFixtureData(named: "codex-wham-usage-fixture.json")
        http.getResponses = [.success(body)]

        let authData = try loadFixtureData(named: "codex-auth-subscription.json")
        let authURL = try makeTempAuthFile(content: authData)
        defer { try? FileManager.default.removeItem(at: authURL) }
        let loader = CodexCredentialLoader(authPath: authURL)

        let client = CodexOAuthClient(http: http, credentialLoader: loader)
        let response = try await client.fetchUsage()

        #expect(response.planType == "plus")
        #expect(response.rateLimit?.primaryWindow?.usedPercent == 48)

        // Request shape
        #expect(http.calls.count == 1)
        let call = try #require(http.calls.first)
        #expect(call.method == "GET")
        #expect(call.url == CodexOAuthClient.endpoint)
        #expect(call.url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        // Bearer is wrapped in Secret — description always redacts
        let bearer = try #require(call.bearer)
        #expect(String(describing: bearer) == "<redacted>")
        // ChatGPT-Account-Id header forwarded from tokens.account_id
        #expect(call.extraHeaders["ChatGPT-Account-Id"] == "d9295b13-fake-account-id-cccc")
        #expect(call.extraHeaders["Accept"] == "application/json")
        #expect(call.extraHeaders["User-Agent"] == "Agents-Usage-Bar/1.0")
    }

    // MARK: - 2. No-accountId path → header omitted

    @Test func noAccountIdInAuthFile_omitsChatGPTAccountIdHeader() async throws {
        let http = FakeCodexHTTPClient()
        let body = try loadFixtureData(named: "codex-wham-usage-fixture.json")
        http.getResponses = [.success(body)]

        // Personal subscription auth — access_token present, account_id absent
        let personalBody = """
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "access_token": "FAKE-personal-token-jjjj"
          }
        }
        """
        let authURL = try makeTempAuthFile(content: Data(personalBody.utf8))
        defer { try? FileManager.default.removeItem(at: authURL) }
        let loader = CodexCredentialLoader(authPath: authURL)

        let client = CodexOAuthClient(http: http, credentialLoader: loader)
        _ = try await client.fetchUsage()

        let call = try #require(http.calls.first)
        #expect(call.extraHeaders["ChatGPT-Account-Id"] == nil)
        #expect(call.extraHeaders.keys.contains("Accept"))
    }

    // MARK: - 3. 401 → unauthorized(status: 401)

    @Test func http401_throwsUnauthorized401() async throws {
        let http = FakeCodexHTTPClient()
        http.getResponses = [.failure(HTTPError(status: 401))]

        let authData = try loadFixtureData(named: "codex-auth-subscription.json")
        let authURL = try makeTempAuthFile(content: authData)
        defer { try? FileManager.default.removeItem(at: authURL) }

        let client = CodexOAuthClient(
            http: http,
            credentialLoader: CodexCredentialLoader(authPath: authURL)
        )
        await #expect(throws: CodexOAuthError.unauthorized(status: 401)) {
            _ = try await client.fetchUsage()
        }
    }

    // MARK: - 4. 403 → unauthorized(status: 403)

    @Test func http403_throwsUnauthorized403() async throws {
        let http = FakeCodexHTTPClient()
        http.getResponses = [.failure(HTTPError(status: 403))]

        let authData = try loadFixtureData(named: "codex-auth-subscription.json")
        let authURL = try makeTempAuthFile(content: authData)
        defer { try? FileManager.default.removeItem(at: authURL) }

        let client = CodexOAuthClient(
            http: http,
            credentialLoader: CodexCredentialLoader(authPath: authURL)
        )
        await #expect(throws: CodexOAuthError.unauthorized(status: 403)) {
            _ = try await client.fetchUsage()
        }
    }

    // MARK: - 5. 429 → usageEndpointFailed(status: 429)

    @Test func http429_throwsUsageEndpointFailed429() async throws {
        let http = FakeCodexHTTPClient()
        http.getResponses = [.failure(HTTPError(status: 429))]

        let authData = try loadFixtureData(named: "codex-auth-subscription.json")
        let authURL = try makeTempAuthFile(content: authData)
        defer { try? FileManager.default.removeItem(at: authURL) }

        let client = CodexOAuthClient(
            http: http,
            credentialLoader: CodexCredentialLoader(authPath: authURL)
        )
        await #expect(throws: CodexOAuthError.usageEndpointFailed(status: 429)) {
            _ = try await client.fetchUsage()
        }
    }

    // MARK: - 6. 500 → usageEndpointFailed(status: 500)

    @Test func http500_throwsUsageEndpointFailed500() async throws {
        let http = FakeCodexHTTPClient()
        http.getResponses = [.failure(HTTPError(status: 500))]

        let authData = try loadFixtureData(named: "codex-auth-subscription.json")
        let authURL = try makeTempAuthFile(content: authData)
        defer { try? FileManager.default.removeItem(at: authURL) }

        let client = CodexOAuthClient(
            http: http,
            credentialLoader: CodexCredentialLoader(authPath: authURL)
        )
        await #expect(throws: CodexOAuthError.usageEndpointFailed(status: 500)) {
            _ = try await client.fetchUsage()
        }
    }

    // MARK: - 7. No credentials → noCredentials

    @Test func loaderReturnsNil_throwsNoCredentials() async throws {
        let http = FakeCodexHTTPClient()
        // Loader points at a nonexistent file → loadCredentials() returns nil
        let nonexistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let client = CodexOAuthClient(
            http: http,
            credentialLoader: CodexCredentialLoader(authPath: nonexistent)
        )
        await #expect(throws: CodexOAuthError.noCredentials) {
            _ = try await client.fetchUsage()
        }
        // No HTTP call should happen
        #expect(http.calls.isEmpty)
    }

    // MARK: - 8. Malformed JSON 200 body → DecodingError (NOT remapped)

    @Test func malformed200Body_throwsDecodingError_notRemapped() async throws {
        let http = FakeCodexHTTPClient()
        http.getResponses = [.success(Data("{ this is not valid json".utf8))]

        let authData = try loadFixtureData(named: "codex-auth-subscription.json")
        let authURL = try makeTempAuthFile(content: authData)
        defer { try? FileManager.default.removeItem(at: authURL) }

        let client = CodexOAuthClient(
            http: http,
            credentialLoader: CodexCredentialLoader(authPath: authURL)
        )
        do {
            _ = try await client.fetchUsage()
            Issue.record("Expected DecodingError")
        } catch is DecodingError {
            // Correct: DecodingError passes through unchanged
        } catch let codexErr as CodexOAuthError {
            Issue.record("DecodingError was incorrectly remapped to \(codexErr)")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - 9. SEC-02 — client source MUST NOT call revealForRequest

    /// Guards SEC-01 invariant: only `URLSessionHTTPClient.performGet` may call
    /// the credential-reveal accessor. If a future refactor inlines that call
    /// into `CodexOAuthClient`, this test fails — bearer strings would then leak
    /// outside the HTTP-client boundary into log lines / error messages.
    @Test func clientSource_doesNotCallRevealForRequest() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let clientURL = thisFile
            .deletingLastPathComponent() // ProvidersCodexTests
            .deletingLastPathComponent() // AgentsUsageBarTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("AgentsUsageBar")
            .appendingPathComponent("Providers")
            .appendingPathComponent("Codex")
            .appendingPathComponent("CodexOAuthClient.swift")
        let source = try String(contentsOf: clientURL, encoding: .utf8)
        #expect(!source.contains("revealForRequest"),
                "SEC-01 violation: CodexOAuthClient must not call revealForRequest()")
    }
}

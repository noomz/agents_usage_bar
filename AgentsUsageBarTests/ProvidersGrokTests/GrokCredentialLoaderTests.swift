import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("GrokCredentialLoaderTests")
struct GrokCredentialLoaderTests {

    @Test func session_wins_over_apiKey_env() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuth(in: dir, key: "session-token-fixture")
        let loader = GrokCredentialLoader(
            authPath: dir.appending(path: "auth.json"),
            piAuthPath: dir.appending(path: "missing-pi-auth.json"),
            environment: ["XAI_API_KEY": "env-api-key-fixture"]
        )
        let result = loader.loadCredentials()
        #expect(result?.source == .session)
        #expect(result?.token.revealForRequest() == "session-token-fixture")
    }

    @Test func empty_apiKey_env_falls_through_to_session() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuth(in: dir, key: "session-token-fixture")
        let loader = GrokCredentialLoader(
            authPath: dir.appending(path: "auth.json"),
            piAuthPath: dir.appending(path: "missing-pi-auth.json"),
            environment: ["XAI_API_KEY": ""]
        )
        let result = loader.loadCredentials()
        #expect(result?.source == .session)
        #expect(result?.token.revealForRequest() == "session-token-fixture")
    }

    @Test func session_key_from_issuer_keyed_auth_json() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuth(in: dir, key: "session-token-fixture")
        let loader = GrokCredentialLoader(
            authPath: dir.appending(path: "auth.json"),
            piAuthPath: dir.appending(path: "missing-pi-auth.json"),
            environment: [:]
        )
        let result = loader.loadCredentials()
        #expect(result?.source == .session)
        #expect(result?.token.revealForRequest() == "session-token-fixture")
    }

    @Test func missing_auth_returns_nil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = GrokCredentialLoader(
            authPath: dir.appending(path: "auth.json"),
            piAuthPath: dir.appending(path: "missing-pi-auth.json"),
            environment: [:]
        )
        #expect(loader.loadCredentials() == nil)
    }

    @Test func secret_description_is_redacted() throws {
        let loader = GrokCredentialLoader(
            authPath: URL(fileURLWithPath: "/tmp/does-not-exist-auth.json"),
            piAuthPath: URL(fileURLWithPath: "/tmp/does-not-exist-pi-auth.json"),
            environment: ["XAI_API_KEY": "env-api-key-fixture"]
        )
        #expect(loader.loadCredentials()?.token.description == "<redacted>")
    }

    @Test func source_does_not_log_token_literals() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "AgentsUsageBar/Providers/Grok/GrokCredentialLoader.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("revealForRequest") == false)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "GrokCredTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeAuth(in dir: URL, key: String) throws {
        let json = """
        { "https://auth.x.ai::fixture": { "key": "\(key)", "auth_mode": "oauth" } }
        """
        try Data(json.utf8).write(to: dir.appending(path: "auth.json"))
    }

    @Test func pi_oauth_after_session_in_candidates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuth(in: dir, key: "session-token-fixture")
        let piAuth = dir.appending(path: "pi-auth.json")
        try writePiAuth(at: piAuth, access: "pi-access-fixture", expires: 2_000_000_000)
        let loader = GrokCredentialLoader(
            authPath: dir.appending(path: "auth.json"),
            piAuthPath: piAuth,
            environment: [:]
        )
        let candidates = loader.loadCandidates()
        #expect(candidates.map(\.source) == [.session, .piOAuth])
        #expect(candidates[1].token.revealForRequest() == "pi-access-fixture")
        #expect(candidates[1].usesGrokCLIHeaders == false)
    }

    @Test func expired_pi_oauth_is_skipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let piAuth = dir.appending(path: "pi-auth.json")
        try writePiAuth(at: piAuth, access: "pi-access-fixture", expires: 1)
        let loader = GrokCredentialLoader(
            authPath: dir.appending(path: "missing-grok-auth.json"),
            piAuthPath: piAuth,
            environment: [:],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(loader.loadCandidates().isEmpty)
    }

    @Test func pi_oauth_only_when_no_grok_session() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let piAuth = dir.appending(path: "pi-auth.json")
        try writePiAuth(at: piAuth, access: "pi-access-fixture", expires: 2_000_000_000)
        let loader = GrokCredentialLoader(
            authPath: dir.appending(path: "missing-grok-auth.json"),
            piAuthPath: piAuth,
            environment: [:]
        )
        #expect(loader.loadCredentials()?.source == .piOAuth)
    }

    private func writePiAuth(at url: URL, access: String, expires: Int) throws {
        let json = """
        { "xai": { "type": "oauth", "access": "\(access)", "refresh": "r", "expires": \(expires) } }
        """
        try Data(json.utf8).write(to: url)
    }
}

@Suite("GrokBillingClient Pi OAuth fallback")
struct GrokBillingClientPiOAuthTests {

    @Test func session_401_then_pi_oauth_succeeds() async throws {
        let http = GrokBillingHeaderHTTPFake()
        http.cliUnauthorized = true
        http.successBody = Data(#"{ "config": { "creditUsagePercent": 5.0, "isUnifiedBillingUser": true, "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-11-05T11:08:00Z" } } }"#.utf8)
        let client = GrokBillingClient(
            http: http,
            loadCandidates: {
                [
                    GrokCredentialLoader.Result(token: Secret("dead-session"), source: .session),
                    GrokCredentialLoader.Result(token: Secret("pi-access-fixture"), source: .piOAuth),
                ]
            }
        )
        let billing = try await client.fetchCredits()
        #expect(billing.creditUsagePercent == 5)
        #expect(http.cliCalls == 1)
        #expect(http.plainCalls == 1)
    }
}

final class GrokBillingHeaderHTTPFake: HTTPClient, @unchecked Sendable {
    var cliUnauthorized = false
    var successBody = Data("{}".utf8)
    var cliCalls = 0
    var plainCalls = 0

    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret,
        extraHeaders: [String: String],
        useSnakeCaseConversion: Bool,
        as type: T.Type
    ) async throws -> T {
        if extraHeaders["x-grok-client-mode"] == "cli" {
            cliCalls += 1
            if cliUnauthorized {
                throw HTTPError(status: 401)
            }
        } else {
            plainCalls += 1
        }
        return try JSONDecoder().decode(T.self, from: successBody)
    }

    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret?,
        extraHeaders: [String: String],
        useSnakeCaseConversion: Bool,
        as type: T.Type
    ) async throws -> T {
        try await get(url, bearer: bearer ?? Secret(""), extraHeaders: extraHeaders, useSnakeCaseConversion: useSnakeCaseConversion, as: type)
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        throw HTTPError(status: 501)
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        bearer: Secret,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        throw HTTPError(status: 501)
    }

    func postFormURLEncoded<T: Decodable & Sendable>(
        _ url: URL,
        formFields: [(String, String)],
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        throw HTTPError(status: 501)
    }
}

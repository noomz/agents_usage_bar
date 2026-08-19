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
            environment: [:]
        )
        #expect(loader.loadCredentials() == nil)
    }

    @Test func secret_description_is_redacted() throws {
        let loader = GrokCredentialLoader(
            authPath: URL(fileURLWithPath: "/tmp/does-not-exist-auth.json"),
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
}

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
        .appendingPathComponent("test-codex-auth-\(UUID().uuidString).json")
    try content.write(to: url)
    return url
}

private func makeTempAuthFile(string: String) throws -> URL {
    try makeTempAuthFile(content: Data(string.utf8))
}

// MARK: - CodexCredentialLoaderTests

@Suite("CodexCredentialLoaderTests")
struct CodexCredentialLoaderTests {

    // MARK: - 1. Missing file → nil

    @Test func missingFile_returnsNil_withoutThrowing() {
        let nonexistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-codex-\(UUID().uuidString).json")
        let loader = CodexCredentialLoader(authPath: nonexistent)
        #expect(loader.loadCredentials() == nil)
    }

    // MARK: - 2. Subscription-only fixture → .subscription + accountId

    @Test func subscriptionFixture_resolvesAccessToken_andAccountId_andSecretIsRedacted() throws {
        let data = try loadFixtureData(named: "codex-auth-subscription.json")
        let url = try makeTempAuthFile(content: data)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = CodexCredentialLoader(authPath: url)
        let result = try #require(loader.loadCredentials())

        #expect(result.source == .subscription)
        #expect(result.bearer.accountId == "d9295b13-fake-account-id-cccc")
        // SEC-01: token is Secret-wrapped → description always redacts.
        #expect(String(describing: result.bearer.token) == "<redacted>")
        // Sanity: revealed-for-request still yields the original string (HTTP path only).
        #expect(result.bearer.token.revealForRequest() == "FAKE-access-token-eyJhbGci-bbbb")
    }

    // MARK: - 3. API-key fixture → .apiKey + accountId nil (precedence)

    @Test func apiKeyFixture_takesPrecedenceOverTokens_andAccountIdIsNil() throws {
        let data = try loadFixtureData(named: "codex-auth-apikey.json")
        let url = try makeTempAuthFile(content: data)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = CodexCredentialLoader(authPath: url)
        let result = try #require(loader.loadCredentials())

        #expect(result.source == .apiKey)
        #expect(result.bearer.accountId == nil)
        #expect(String(describing: result.bearer.token) == "<redacted>")
        #expect(result.bearer.token.revealForRequest() == "FAKE-api-key-xyz-direct-bearer-aaaa")
    }

    // MARK: - 4. Empty-tokens fixture → nil

    @Test func emptyTokensFixture_returnsNil() throws {
        let data = try loadFixtureData(named: "codex-auth-empty.json")
        let url = try makeTempAuthFile(content: data)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = CodexCredentialLoader(authPath: url)
        #expect(loader.loadCredentials() == nil)
    }

    // MARK: - 5. Malformed JSON file → nil (best-effort, no throw)

    @Test func malformedJSON_returnsNil_withoutThrowing() throws {
        let url = try makeTempAuthFile(string: "{ this is not json")
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = CodexCredentialLoader(authPath: url)
        #expect(loader.loadCredentials() == nil)
    }

    // MARK: - 6. OPENAI_API_KEY = "" treated as absent → falls through to tokens

    @Test func emptyApiKeyString_fallsThroughToTokensAccessToken() throws {
        let body = """
        {
          "OPENAI_API_KEY": "",
          "tokens": {
            "access_token": "FAKE-fallthrough-token-ffff",
            "account_id": "ws-fallthrough-gggg"
          }
        }
        """
        let url = try makeTempAuthFile(string: body)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = CodexCredentialLoader(authPath: url)
        let result = try #require(loader.loadCredentials())
        #expect(result.source == .subscription)
        #expect(result.bearer.accountId == "ws-fallthrough-gggg")
        #expect(result.bearer.token.revealForRequest() == "FAKE-fallthrough-token-ffff")
    }

    // MARK: - 7. accountId nil when missing (personal subscription account)

    @Test func accountId_isNil_whenMissingFromTokens() throws {
        let body = """
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "access_token": "FAKE-personal-account-token-hhhh"
          }
        }
        """
        let url = try makeTempAuthFile(string: body)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = CodexCredentialLoader(authPath: url)
        let result = try #require(loader.loadCredentials())
        #expect(result.source == .subscription)
        #expect(result.bearer.accountId == nil)
    }

    // MARK: - 8. Both OPENAI_API_KEY null AND tokens absent → nil

    @Test func neitherCredentialPath_returnsNil() throws {
        let body = """
        {
          "last_refresh": "2026-05-13T11:47:21Z",
          "OPENAI_API_KEY": null
        }
        """
        let url = try makeTempAuthFile(string: body)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = CodexCredentialLoader(authPath: url)
        #expect(loader.loadCredentials() == nil)
    }
}

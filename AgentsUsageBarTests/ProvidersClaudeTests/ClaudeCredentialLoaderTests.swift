import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - FakeKeychain

/// Controllable test double for KeychainProtocol.
/// Thread-safe via @unchecked Sendable (controlled in tests only).
final class FakeKeychain: KeychainProtocol, @unchecked Sendable {
    enum Behavior {
        case returnData(Data)
        case throwError(KeychainReaderError)
    }

    var readBehavior: Behavior = .throwError(.itemNotFound)
    var writtenData: Data?
    var writtenService: String?

    func readGenericPassword(service: String, account: String?) throws -> Data {
        switch readBehavior {
        case .returnData(let data): return data
        case .throwError(let err): throw err
        }
    }

    func writeGenericPassword(_ data: Data, service: String, account: String?) throws {
        writtenData = data
        writtenService = service
    }
}

// MARK: - Fixture helpers

private func loadFixtureData(named name: String) throws -> Data {
    let thisFile = URL(fileURLWithPath: #filePath)
    let fixtureURL = thisFile
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    return try Data(contentsOf: fixtureURL)
}

private func makeTempFile(content: Data) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test-credentials-\(UUID().uuidString).json")
    try content.write(to: url)
    return url
}

private func makeTempFile(string: String) throws -> URL {
    try makeTempFile(content: Data(string.utf8))
}

// MARK: - ClaudeCredentialLoaderTests

@Suite("ClaudeCredentialLoaderTests", .serialized)
struct ClaudeCredentialLoaderTests {

    // MARK: - File resolution tests

    @Test func loadFromFile_decodesClaudeAiOauthShape() throws {
        let data = try loadFixtureData(named: "credentials-claudeAiOauth-shape.json")
        let tempURL = try makeTempFile(content: data)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let loader = ClaudeCredentialLoader(
            keychain: FakeKeychain(),
            env: [:],
            credentialsPath: tempURL
        )
        let result = try #require(loader.loadCredentials())
        #expect(result.oauth.accessToken == "fake-claude-access-token-aaaa")
        #expect(result.oauth.refreshToken == "fake-claude-refresh-token-bbbb")
        #expect(result.oauth.expiresAt == 1799999999000.0)
        #expect(result.oauth.subscriptionType == "claude_max")
        #expect(result.source == .file)
    }

    @Test func loadFromFile_decodesMcpOAuthShape() throws {
        let data = try loadFixtureData(named: "credentials-mcpOAuth-shape.json")
        let tempURL = try makeTempFile(content: data)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let loader = ClaudeCredentialLoader(
            keychain: FakeKeychain(),
            env: [:],
            credentialsPath: tempURL
        )
        let result = try #require(loader.loadCredentials())
        #expect(result.oauth.accessToken == "fake-mcp-access-token-cccc")
        #expect(result.source == .file)
    }

    @Test func loadFromFile_missingFile_returnsNil() throws {
        let nonexistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let loader = ClaudeCredentialLoader(
            keychain: FakeKeychain(),
            env: [:],
            credentialsPath: nonexistent
        )
        #expect(loader.loadCredentials() == nil)
    }

    @Test func loadFromFile_invalidJSON_returnsNil() throws {
        let tempURL = try makeTempFile(string: "not json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let loader = ClaudeCredentialLoader(
            keychain: FakeKeychain(),
            env: [:],
            credentialsPath: tempURL
        )
        #expect(loader.loadCredentials() == nil)
    }

    @Test func loadFromFile_missingAccessToken_returnsNil() throws {
        let tempURL = try makeTempFile(string: #"{"claudeAiOauth": {}}"#)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let loader = ClaudeCredentialLoader(
            keychain: FakeKeychain(),
            env: [:],
            credentialsPath: tempURL
        )
        #expect(loader.loadCredentials() == nil)
    }

    @Test func loadFromFile_emptyAccessToken_returnsNil() throws {
        let tempURL = try makeTempFile(string: #"{"claudeAiOauth": {"accessToken": ""}}"#)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let loader = ClaudeCredentialLoader(
            keychain: FakeKeychain(),
            env: [:],
            credentialsPath: tempURL
        )
        #expect(loader.loadCredentials() == nil)
    }

    // MARK: - Keychain resolution tests

    @Test func loadFromKeychain_returnsResult_whenItemExists() throws {
        let data = try loadFixtureData(named: "credentials-claudeAiOauth-shape.json")
        let fakeKeychain = FakeKeychain()
        fakeKeychain.readBehavior = .returnData(data)

        // Nonexistent file so keychain is tried
        let nonexistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let loader = ClaudeCredentialLoader(
            keychain: fakeKeychain,
            env: [:],
            credentialsPath: nonexistent
        )
        let result = try #require(loader.loadCredentials())
        #expect(result.oauth.accessToken == "fake-claude-access-token-aaaa")
        #expect(result.source == .keychain)
    }

    @Test func loadFromKeychain_swallowsItemNotFound_andFallsThrough() throws {
        let fakeKeychain = FakeKeychain()
        fakeKeychain.readBehavior = .throwError(.itemNotFound)
        let nonexistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let loader = ClaudeCredentialLoader(
            keychain: fakeKeychain,
            env: [:],
            credentialsPath: nonexistent
        )
        // Must return nil without throwing
        #expect(loader.loadCredentials() == nil)
    }

    @Test func loadFromKeychain_swallowsAuthFailed_andFallsThrough() throws {
        let fakeKeychain = FakeKeychain()
        fakeKeychain.readBehavior = .throwError(.authFailed)
        let nonexistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let loader = ClaudeCredentialLoader(
            keychain: fakeKeychain,
            env: [:],
            credentialsPath: nonexistent
        )
        #expect(loader.loadCredentials() == nil)
    }

    // MARK: - Env resolution tests

    @Test func loadFromEnv_returnsLongLivedToken_whenSet() throws {
        let nonexistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let fakeKeychain = FakeKeychain()
        fakeKeychain.readBehavior = .throwError(.itemNotFound)
        let loader = ClaudeCredentialLoader(
            keychain: fakeKeychain,
            env: ["CLAUDE_CODE_OAUTH_TOKEN": "fake-env-token-eeee"],
            credentialsPath: nonexistent
        )
        let result = try #require(loader.loadCredentials())
        #expect(result.oauth.accessToken == "fake-env-token-eeee")
        #expect(result.oauth.refreshToken == nil)
        #expect(result.oauth.expiresAt == nil)
        #expect(result.oauth.subscriptionType == nil)
        #expect(result.source == .environment)
    }

    @Test func loadFromEnv_emptyString_returnsNil() throws {
        let nonexistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let fakeKeychain = FakeKeychain()
        fakeKeychain.readBehavior = .throwError(.itemNotFound)
        let loader = ClaudeCredentialLoader(
            keychain: fakeKeychain,
            env: ["CLAUDE_CODE_OAUTH_TOKEN": ""],
            credentialsPath: nonexistent
        )
        #expect(loader.loadCredentials() == nil)
    }

    // MARK: - Precedence tests

    @Test func precedence_filePresent_overridesKeychainAndEnv() throws {
        let data = try loadFixtureData(named: "credentials-claudeAiOauth-shape.json")
        let tempURL = try makeTempFile(content: data)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Keychain has different data
        let mcpData = try loadFixtureData(named: "credentials-mcpOAuth-shape.json")
        let fakeKeychain = FakeKeychain()
        fakeKeychain.readBehavior = .returnData(mcpData)

        let loader = ClaudeCredentialLoader(
            keychain: fakeKeychain,
            env: ["CLAUDE_CODE_OAUTH_TOKEN": "fake-env-token-eeee"],
            credentialsPath: tempURL
        )
        let result = try #require(loader.loadCredentials())
        #expect(result.source == .file)
        #expect(result.oauth.accessToken == "fake-claude-access-token-aaaa")
    }

    @Test func precedence_fileDecodeFails_fallsBackToKeychain() throws {
        // File exists but claudeAiOauth has no accessToken
        let tempURL = try makeTempFile(string: #"{"claudeAiOauth": {"accessToken": ""}}"#)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let data = try loadFixtureData(named: "credentials-claudeAiOauth-shape.json")
        let fakeKeychain = FakeKeychain()
        fakeKeychain.readBehavior = .returnData(data)

        let loader = ClaudeCredentialLoader(
            keychain: fakeKeychain,
            env: [:],
            credentialsPath: tempURL
        )
        let result = try #require(loader.loadCredentials())
        #expect(result.source == .keychain)
        #expect(result.oauth.accessToken == "fake-claude-access-token-aaaa")
    }

    // MARK: - needsRefresh tests

    @Test func needsRefresh_nilExpiresAt_returnsTrue() {
        let loader = ClaudeCredentialLoader(keychain: FakeKeychain(), env: [:], credentialsPath: nil)
        let oauth = ClaudeCredentialLoader.OAuth(
            accessToken: "tok", refreshToken: nil, expiresAt: nil, subscriptionType: nil
        )
        #expect(loader.needsRefresh(oauth) == true)
    }

    @Test func needsRefresh_inFutureBeyondBuffer_returnsFalse() {
        let loader = ClaudeCredentialLoader(keychain: FakeKeychain(), env: [:], credentialsPath: nil)
        let now = Date()
        // expiresAt = now + 1 hour (in ms)
        let expiresAt = (now.timeIntervalSince1970 + 3600) * 1000
        let oauth = ClaudeCredentialLoader.OAuth(
            accessToken: "tok", refreshToken: nil, expiresAt: expiresAt, subscriptionType: nil
        )
        #expect(loader.needsRefresh(oauth, now: now) == false)
    }

    @Test func needsRefresh_withinBuffer_returnsTrue() {
        let loader = ClaudeCredentialLoader(keychain: FakeKeychain(), env: [:], credentialsPath: nil)
        let now = Date()
        // expiresAt = now + 2 minutes (in ms) — within default 5-minute buffer
        let expiresAt = (now.timeIntervalSince1970 + 120) * 1000
        let oauth = ClaudeCredentialLoader.OAuth(
            accessToken: "tok", refreshToken: nil, expiresAt: expiresAt, subscriptionType: nil
        )
        #expect(loader.needsRefresh(oauth, now: now) == true)
    }

    // MARK: - saveCredentials tests

    @Test func saveCredentials_toFile_writesClaudeAiOauthEnvelope() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-save-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let loader = ClaudeCredentialLoader(
            keychain: FakeKeychain(),
            env: [:],
            credentialsPath: tempURL
        )
        let oauth = ClaudeCredentialLoader.OAuth(
            accessToken: "test-access",
            refreshToken: "test-refresh",
            expiresAt: 1234567890000.0,
            subscriptionType: "claude_max"
        )
        try loader.saveCredentials(oauth, to: .file)

        let data = try Data(contentsOf: tempURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Saved file is not valid JSON")
            return
        }
        let blob = try #require(json["claudeAiOauth"] as? [String: Any])
        #expect(blob["accessToken"] as? String == "test-access")
        #expect(blob["refreshToken"] as? String == "test-refresh")
        #expect(blob["expiresAt"] as? Double == 1234567890000.0)
        #expect(blob["subscriptionType"] as? String == "claude_max")
    }

    @Test func saveCredentials_toKeychain_invokesWriteGenericPassword() throws {
        let fakeKeychain = FakeKeychain()
        let loader = ClaudeCredentialLoader(
            keychain: fakeKeychain,
            env: [:],
            credentialsPath: nil
        )
        let oauth = ClaudeCredentialLoader.OAuth(
            accessToken: "test-access",
            refreshToken: "test-refresh",
            expiresAt: nil,
            subscriptionType: nil
        )
        try loader.saveCredentials(oauth, to: .keychain)

        #expect(fakeKeychain.writtenService == "Claude Code-credentials")
        let data = try #require(fakeKeychain.writtenData)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Keychain data is not valid JSON")
            return
        }
        let blob = try #require(json["claudeAiOauth"] as? [String: Any])
        #expect(blob["accessToken"] as? String == "test-access")
    }

    @Test func saveCredentials_toEnvironment_isNoOp() throws {
        let fakeKeychain = FakeKeychain()
        let loader = ClaudeCredentialLoader(
            keychain: fakeKeychain,
            env: [:],
            credentialsPath: nil
        )
        let oauth = ClaudeCredentialLoader.OAuth(
            accessToken: "test-access",
            refreshToken: nil,
            expiresAt: nil,
            subscriptionType: nil
        )
        // Must not throw
        try loader.saveCredentials(oauth, to: .environment)
        // No keychain write occurred
        #expect(fakeKeychain.writtenData == nil)
    }

    // MARK: - UsageSnapshot backwards-compat regression

    @Test func usageSnapshot_quotaWindows_defaultsToNil() {
        let snap = UsageSnapshot(
            providerID: .openrouter,
            asOf: Date(),
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: [:]
        )
        #expect(snap.quotaWindows == nil)
    }
}

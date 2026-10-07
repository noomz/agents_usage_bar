import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("CodexLoginDiscovery")
struct CodexLoginDiscoveryTests {
    private let plusToken = "test-token-plus"
    private let teamToken = "test-token-team"
    private let authToken = "test-token-auth"

    @Test func registrationRequiresCredentialsSessionsOrALogin() {
        #expect(CodexLoginDiscovery.shouldRegister(hasCredentials: false, sessionsExist: false, loginCount: 0) == false)
        #expect(CodexLoginDiscovery.shouldRegister(hasCredentials: true, sessionsExist: false, loginCount: 0))
        #expect(CodexLoginDiscovery.shouldRegister(hasCredentials: false, sessionsExist: true, loginCount: 0))
        #expect(CodexLoginDiscovery.shouldRegister(hasCredentials: false, sessionsExist: false, loginCount: 1))
    }

    @Test func missingDirectoryAndMissingAuthReturnNoLogins() {
        let missingDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-missing-\(UUID().uuidString)", isDirectory: true)
        let missingAuth = missingDir.appendingPathComponent("auth.json")
        let logins = CodexLoginDiscovery.discover(directory: missingDir, authPath: missingAuth)
        #expect(logins.isEmpty)
    }

    @Test func uniquePlanSlugsAreLowercasedSortedAndTokensStayRedacted() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        try writeCLIProxy(
            dir,
            filename: "codex-bbbbbbbb-b@example.com-TEAM.json",
            accountId: "bbbbbbbb-2222",
            token: teamToken,
            email: "b@example.com"
        )
        try writeCLIProxy(
            dir,
            filename: "codex-aaaaaaaa-a@example.com-Plus.json",
            accountId: "aaaaaaaa-1111",
            token: plusToken,
            email: "a@example.com",
            extra: #""priority": 1, "expired": "2099-01-01","#
        )
        let logins = CodexLoginDiscovery.discover(directory: dir, authPath: dir.appendingPathComponent("auth.json"))
        let labeled = CodexLoginDiscovery.labeled(logins)
        #expect(labeled.map(\.label) == ["plus", "team"])
        #expect(labeled[0].login.accessToken.revealForRequest() == plusToken)
        #expect(labeled[1].login.source == .cliproxy(filename: "codex-bbbbbbbb-b@example.com-TEAM.json"))
        let rendered = String(describing: labeled)
        #expect(!rendered.contains(plusToken))
        #expect(!rendered.contains(teamToken))
        #expect(rendered.contains("<redacted>"))
    }

    @Test func duplicatePlanSlugUsesUniqueEmailsInCodeUnitOrder() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        try writeCLIProxy(
            dir,
            filename: "codex-aaaaaaaa-zoo@example.com-plus.json",
            accountId: "aaaaaaaa-1111",
            token: plusToken,
            email: "zoo@example.com"
        )
        try writeCLIProxy(
            dir,
            filename: "codex-bbbbbbbb-Alpha@example.com-plus.json",
            accountId: "bbbbbbbb-2222",
            token: teamToken,
            email: "Alpha@example.com"
        )
        let labeled = CodexLoginDiscovery.labeled(
            CodexLoginDiscovery.discover(directory: dir, authPath: dir.appendingPathComponent("auth.json"))
        )
        #expect(labeled.map(\.label) == ["Alpha@example.com", "zoo@example.com"])
    }

    @Test func missingOrDuplicateEmailSkipsToAccountPrefixThenFullId() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        try writeCLIProxy(
            dir,
            filename: "codex-aaaaaaaa-a@example.com-plus.json",
            accountId: "aaaaaaaa-1111",
            token: plusToken,
            email: "same@example.com"
        )
        try writeCLIProxy(
            dir,
            filename: "codex-bbbbbbbb-b@example.com-plus.json",
            accountId: "aaaaaaaa-2222",
            token: teamToken,
            email: "same@example.com"
        )
        try writeCLIProxy(
            dir,
            filename: "codex-cccccccc-c@example.com-team.json",
            accountId: "cccccccc-3333",
            token: authToken,
            email: ""
        )
        let labeled = CodexLoginDiscovery.labeled(
            CodexLoginDiscovery.discover(directory: dir, authPath: dir.appendingPathComponent("auth.json"))
        )
        #expect(labeled.map(\.label) == [
            "acct-aaaaaaaa-1111",
            "acct-aaaaaaaa-2222",
            "team",
        ])
    }

    @Test func emailThatMatchesAnotherSlugFallsForward() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        try writeCLIProxy(
            dir,
            filename: "codex-aaaaaaaa-a@example.com-plus.json",
            accountId: "aaaaaaaa-1111",
            token: plusToken,
            email: "a@example.com"
        )
        try writeCLIProxy(
            dir,
            filename: "codex-bbbbbbbb-b@example.com-custom.json",
            accountId: "bbbbbbbb-2222",
            token: teamToken,
            email: "plus"
        )
        let labeled = CodexLoginDiscovery.labeled(
            CodexLoginDiscovery.discover(directory: dir, authPath: dir.appendingPathComponent("auth.json"))
        )
        #expect(labeled.map(\.label) == ["a@example.com", "acct-bbbbbbbb"])
    }

    @Test func skippedFilesDoNotDropAValidSibling() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        try Data("{".utf8).write(to: dir.appendingPathComponent("codex-00000000-bad@example.com-plus.json"))
        try writeCLIProxy(
            dir,
            filename: "codex-11111111-off@example.com-pro.json",
            accountId: "11111111-1111",
            token: plusToken,
            email: "off@example.com",
            disabled: true
        )
        try writeCLIProxy(
            dir,
            filename: "codex-22222222-other@example.com-team.json",
            accountId: "22222222-2222",
            token: teamToken,
            email: "other@example.com",
            type: "openai"
        )
        try writeCLIProxy(
            dir,
            filename: "codex-33333333-empty-token@example.com-plus.json",
            accountId: "33333333-3333",
            token: "",
            email: "empty-token@example.com"
        )
        try writeCLIProxy(
            dir,
            filename: "codex-44444444-empty-id@example.com-plus.json",
            accountId: "",
            token: plusToken,
            email: "empty-id@example.com"
        )
        try Data("notes".utf8).write(to: dir.appendingPathComponent("notes.json"))
        try writeCLIProxy(
            dir,
            filename: "codex-55555555-kept@example.com-edu.json",
            accountId: "55555555-5555",
            token: authToken,
            email: "kept@example.com",
            type: nil
        )
        let logins = CodexLoginDiscovery.discover(directory: dir, authPath: dir.appendingPathComponent("auth.json"))
        #expect(logins.map(\.accountId) == ["55555555-5555"])
        #expect(CodexLoginDiscovery.labeled(logins).map(\.label) == ["edu"])
    }

    @Test func duplicateAccountIdKeepsTheLexicographicallySmallerFilename() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        try writeCLIProxy(
            dir,
            filename: "codex-bbbbbbbb-b@example.com-team.json",
            accountId: "same-account-id",
            token: teamToken,
            email: "b@example.com"
        )
        try writeCLIProxy(
            dir,
            filename: "codex-aaaaaaaa-a@example.com-plus.json",
            accountId: "same-account-id",
            token: plusToken,
            email: "a@example.com"
        )
        let logins = CodexLoginDiscovery.discover(directory: dir, authPath: dir.appendingPathComponent("auth.json"))
        #expect(logins.count == 1)
        #expect(logins[0].source == .cliproxy(filename: "codex-aaaaaaaa-a@example.com-plus.json"))
        #expect(logins[0].accessToken.revealForRequest() == plusToken)
        #expect(CodexLoginDiscovery.labeled(logins).map(\.label) == ["plus"])
    }

    @Test func apiKeyAuthIsNeverALogin() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        let auth = dir.appendingPathComponent("auth.json")
        try Data(#"""
        {"OPENAI_API_KEY":"test-api-key-not-a-login","tokens":{"access_token":"test-token-hidden","account_id":"dddddddd-4444"}}
        """#.utf8).write(to: auth)
        let logins = CodexLoginDiscovery.discover(directory: dir, authPath: auth)
        #expect(logins.isEmpty)
        #expect(!String(describing: logins).contains("test-api-key-not-a-login"))
    }

    @Test func authJsonIsOmittedWhenItsAccountIsAlreadyInCLIProxy() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        try writeCLIProxy(
            dir,
            filename: "codex-aaaaaaaa-a@example.com-plus.json",
            accountId: "aaaaaaaa-1111",
            token: plusToken,
            email: "a@example.com"
        )
        let auth = try writeAuth(dir, accountId: "aaaaaaaa-1111", token: authToken)
        let logins = CodexLoginDiscovery.discover(directory: dir, authPath: auth)
        #expect(logins.count == 1)
        #expect(logins[0].accessToken.revealForRequest() == plusToken)
        #expect(logins[0].source == .cliproxy(filename: "codex-aaaaaaaa-a@example.com-plus.json"))
    }

    @Test func authJsonJoinsWhenItsAccountIsNewAndUsesPlanType() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        try writeCLIProxy(
            dir,
            filename: "codex-aaaaaaaa-a@example.com-team.json",
            accountId: "aaaaaaaa-1111",
            token: plusToken,
            email: "a@example.com"
        )
        let auth = try writeAuth(dir, accountId: "bbbbbbbb-2222", token: authToken)
        let logins = CodexLoginDiscovery.discover(directory: dir, authPath: auth)
        let labeled = CodexLoginDiscovery.labeled(logins, planTypes: ["bbbbbbbb-2222": "Pro"])
        #expect(labeled.map(\.label) == ["pro", "team"])
        #expect(labeled[0].login.source == .authJSON)
        #expect(labeled[0].login.accessToken.revealForRequest() == authToken)
    }

    @Test func authJsonPlanTypeThatMatchesASlugFallsThroughToTheAccountPrefix() throws {
        let dir = try makeDir()
        defer { remove(dir) }
        try writeCLIProxy(
            dir,
            filename: "codex-aaaaaaaa-a@example.com-plus.json",
            accountId: "aaaaaaaa-1111",
            token: plusToken,
            email: "a@example.com"
        )
        let auth = try writeAuth(dir, accountId: "bbbbbbbb-2222", token: authToken)
        let labeled = CodexLoginDiscovery.labeled(
            CodexLoginDiscovery.discover(directory: dir, authPath: auth),
            planTypes: ["bbbbbbbb-2222": "plus"]
        )
        #expect(labeled.map(\.label) == ["acct-bbbbbbbb", "plus"])
    }

    @Test func subscriptionWithoutAccountIdIsALoginOnlyWhenCLIProxyIsEmpty() throws {
        let alone = try makeDir()
        defer { remove(alone) }
        let aloneAuth = try writeAuth(alone, accountId: nil, token: authToken)
        let aloneLogins = CodexLoginDiscovery.discover(directory: alone, authPath: aloneAuth)
        #expect(aloneLogins.count == 1)
        #expect(aloneLogins[0].accountId == nil)
        #expect(aloneLogins[0].source == .authJSON)
        #expect(CodexLoginDiscovery.labeled(aloneLogins, planTypes: ["": "Free"]).map(\.label) == ["free"])

        let withProxy = try makeDir()
        defer { remove(withProxy) }
        try writeCLIProxy(
            withProxy,
            filename: "codex-aaaaaaaa-a@example.com-plus.json",
            accountId: "aaaaaaaa-1111",
            token: plusToken,
            email: "a@example.com"
        )
        let proxyAuth = try writeAuth(withProxy, accountId: nil, token: authToken)
        let proxyLogins = CodexLoginDiscovery.discover(directory: withProxy, authPath: proxyAuth)
        #expect(proxyLogins.map(\.accountId) == ["aaaaaaaa-1111"])
    }

    // MARK: - Fixtures

    private func makeDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-logins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func writeCLIProxy(
        _ dir: URL,
        filename: String,
        accountId: String,
        token: String,
        email: String,
        type: String? = "codex",
        disabled: Bool = false,
        extra: String = ""
    ) throws {
        let typeField = type.map { #""type": "\#($0)","# } ?? ""
        let body = """
        {\(typeField)
        "email": "\(email)",
        "account_id": "\(accountId)",
        "access_token": "\(token)",
        "disabled": \(disabled ? "true" : "false"),
        \(extra)
        "refresh_token": "test-refresh-unused"}
        """
        try Data(body.utf8).write(to: dir.appendingPathComponent(filename))
    }

    private func writeAuth(_ dir: URL, accountId: String?, token: String) throws -> URL {
        let accountField = accountId.map { #""account_id": "\#($0)""# } ?? #""account_id": """#
        let body = """
        {"OPENAI_API_KEY": null, "tokens": {"access_token": "\(token)", \(accountField)}}
        """
        let url = dir.appendingPathComponent("auth.json")
        try Data(body.utf8).write(to: url)
        return url
    }
}

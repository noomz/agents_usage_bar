import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - GeminiCredentialLoaderTests
//
// Plan 03-05 Task 2 — Pitfall 9 (missing-file) + RESEARCH correction #3
// (expiry_date = epoch MILLISECONDS) lock-in tests.

@Suite("GeminiCredentialLoaderTests", .serialized)
struct GeminiCredentialLoaderTests {

    // MARK: - Fixture helpers

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func writeTempCreds(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-creds-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("oauth_creds.json")
        try json.data(using: .utf8)!.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Test 1: happy fixture → source == .file

    @Test func happyFixture_decodesCleanly() throws {
        let loader = GeminiCredentialLoader(credentialsPath: fixtureURL("gemini-oauth-creds-fixture.json"))
        let result = try #require(loader.loadCredentials())
        #expect(result.source == .file)
        #expect(!result.credentials.refreshToken.isEmpty)
        #expect(abs(result.credentials.expiryDate - 1778834115287.89) < 1.0)
    }

    // MARK: - Test 2: expiryDateAsDate() correct ms→Date arithmetic

    @Test func expiryDateAsDate_dividesByThousand() throws {
        let loader = GeminiCredentialLoader(credentialsPath: fixtureURL("gemini-oauth-creds-fixture.json"))
        let result = try #require(loader.loadCredentials())
        let date = result.credentials.expiryDateAsDate()
        #expect(abs(date.timeIntervalSince1970 - 1778834115.28789) < 0.001)
    }

    // MARK: - Test 3: access_token: null → optional decodes to nil

    @Test func accessTokenNull_decodesOptionalNil() throws {
        let url = try writeTempCreds(#"""
        {
          "access_token": null,
          "refresh_token": "FAKE-1//0gb-XXXX",
          "scope": "https://www.googleapis.com/auth/cloud-platform.read-only",
          "id_token": "FAKE-eyJhbGci.signaturePart",
          "expiry_date": 1778834115287.89,
          "token_type": "Bearer"
        }
        """#)
        let result = try #require(GeminiCredentialLoader(credentialsPath: url).loadCredentials())
        #expect(result.credentials.accessToken == nil)
        #expect(result.credentials.refreshToken == "FAKE-1//0gb-XXXX")
    }

    // MARK: - Test 4: expiry_date as plain integer → decodes as Double

    @Test func expiryDateInteger_decodesAsDouble() throws {
        let url = try writeTempCreds(#"""
        {
          "refresh_token": "FAKE-1//0gb-XXXX",
          "expiry_date": 1778834115000
        }
        """#)
        let result = try #require(GeminiCredentialLoader(credentialsPath: url).loadCredentials())
        #expect(result.credentials.expiryDate == 1778834115000.0)
        let date = result.credentials.expiryDateAsDate()
        #expect(abs(date.timeIntervalSince1970 - 1778834115.0) < 0.001)
    }

    // MARK: - Test 5: missing file → nil (Pitfall 9)

    @Test func missingFile_returnsNil() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nonexistent-gemini-\(UUID().uuidString).json")
        #expect(GeminiCredentialLoader(credentialsPath: url).loadCredentials() == nil)
    }

    // MARK: - Test 6: malformed JSON → nil

    @Test func malformedJSON_returnsNil() throws {
        let url = try writeTempCreds("{ not even json ::::")
        #expect(GeminiCredentialLoader(credentialsPath: url).loadCredentials() == nil)
    }

    // MARK: - Test 7: missing refresh_token → nil (DecodingError swallowed)

    @Test func missingRefreshToken_returnsNil() throws {
        let url = try writeTempCreds(#"""
        {
          "access_token": "FAKE-ya29-XXXX",
          "expiry_date": 1778834115287.89
        }
        """#)
        #expect(GeminiCredentialLoader(credentialsPath: url).loadCredentials() == nil)
    }

    // MARK: - Test 8: SEC-04 source-grep gate — credential strings never
    // appear in logger interpolations.
    //
    // Reads the loader's own source file via `#filePath`-anchored repo walk
    // and asserts the only occurrences of `access_token` / `refresh_token`
    // are inside doc comments. The semantic invariant: no `logger.*` call
    // interpolates these tokens.

    @Test func loggerInterpolations_neverIncludeCredentialTokens() throws {
        let repoRoot = repoRootFromTestFile()
        let loaderSource = repoRoot
            .appendingPathComponent("AgentsUsageBar/Providers/Gemini/GeminiCredentialLoader.swift")
        let src = try String(contentsOf: loaderSource, encoding: .utf8)

        // Scan only lines that look like logger interpolations.
        for line in src.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip doc comments / SEC-02 prose.
            if trimmed.hasPrefix("//") { continue }
            // Anything that touches the logger must NOT include creds.
            if trimmed.contains("logger.") {
                #expect(!trimmed.contains("access_token"), "logger leaks access_token: \(trimmed)")
                #expect(!trimmed.contains("refresh_token"), "logger leaks refresh_token: \(trimmed)")
                #expect(!trimmed.contains("expiry_date"), "logger leaks expiry_date: \(trimmed)")
                #expect(!trimmed.contains("revealForRequest"), "logger reveals secret: \(trimmed)")
            }
        }
    }

    private func repoRootFromTestFile() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        // Walk up until we find the AgentsUsageBar.xcodeproj sibling.
        for _ in 0..<10 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("AgentsUsageBar.xcodeproj")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }
}

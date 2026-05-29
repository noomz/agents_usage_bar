import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - FakeGeminiHTTPClient
//
// Test double for `HTTPClient` exercised by `GeminiOAuthClient`. Scripts
// `postFormURLEncoded` responses and captures the raw form body for shape
// assertions (Test 4).

final class FakeGeminiHTTPClient: HTTPClient, @unchecked Sendable {

    struct Call {
        let url: URL
        let method: String
        let bearer: Secret?
        let extraHeaders: [String: String]
        let formBody: String?
    }

    var calls: [Call] = []
    var postFormResponses: [Result<Data, Error>] = []

    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        calls.append(.init(url: url, method: "GET", bearer: bearer, extraHeaders: extraHeaders, formBody: nil))
        throw HTTPError(status: 501, message: "FakeGeminiHTTPClient: GET not scripted")
    }

    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret?,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        calls.append(.init(url: url, method: "GET", bearer: bearer, extraHeaders: extraHeaders, formBody: nil))
        throw HTTPError(status: 501, message: "FakeGeminiHTTPClient: GET not scripted")
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        calls.append(.init(url: url, method: "POST", bearer: nil, extraHeaders: extraHeaders, formBody: nil))
        throw HTTPError(status: 501, message: "FakeGeminiHTTPClient: postJSON not scripted")
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        bearer: Secret,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        // Plan 03-06 widens HTTPClient with bearer-postJSON. Not exercised
        // by the OAuth-client tests (those use the form-urlencoded refresh
        // path); stub keeps the type compiling.
        calls.append(.init(url: url, method: "POST", bearer: bearer, extraHeaders: extraHeaders, formBody: nil))
        throw HTTPError(status: 501, message: "FakeGeminiHTTPClient: postJSON(bearer:) not scripted")
    }

    func postFormURLEncoded<T: Decodable & Sendable>(
        _ url: URL,
        formFields: [(String, String)],
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        // Recreate the exact wire body the production client would form so
        // the test can assert percent-encoding + field ordering.
        let encoded = formFields
            .map { key, value -> String in
                let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(key)=\(v)"
            }
            .joined(separator: "&")
        calls.append(.init(url: url, method: "POST", bearer: nil, extraHeaders: extraHeaders, formBody: encoded))
        guard !postFormResponses.isEmpty else {
            throw HTTPError(status: 500, message: "FakeGeminiHTTPClient: no response scripted")
        }
        switch postFormResponses.removeFirst() {
        case .success(let data):
            // `GeminiTokenRefreshResponse` declares explicit snake_case
            // `CodingKeys`. A `convertFromSnakeCase` strategy would
            // pre-rewrite the JSON keys to camelCase before key lookup
            // and miss the explicit `"access_token"` mapping — mirrors
            // the Codex test fake (CodexOAuthClientTests).
            return try JSONDecoder().decode(T.self, from: data)
        case .failure(let err):
            throw err
        }
    }
}

// MARK: - Fixture helpers

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func loadFixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

private func writeCredsFile(accessToken: String?, refreshToken: String, expiryDate: Double) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gemini-oauth-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("oauth_creds.json")
    let access: String
    if let accessToken {
        access = "\"\(accessToken)\""
    } else {
        access = "null"
    }
    let json = """
    {
      "access_token": \(access),
      "refresh_token": "\(refreshToken)",
      "scope": "https://www.googleapis.com/auth/cloud-platform.read-only",
      "id_token": "FAKE-eyJhbGci.signaturePart",
      "expiry_date": \(expiryDate),
      "token_type": "Bearer"
    }
    """
    try json.data(using: .utf8)!.write(to: url, options: .atomic)
    return url
}

// MARK: - GeminiOAuthClientTests

@Suite("GeminiOAuthClientTests", .serialized)
struct GeminiOAuthClientTests {

    // MARK: - Test 1: Eager cache skip — no stub request

    @Test func eagerCacheHit_doesNotCallHTTP() async throws {
        // Set up: cached access_token with expiry 600s in the future.
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeGeminiHTTPClient()
        let credsURL = try writeCredsFile(
            accessToken: "ignored-because-cache-wins",
            refreshToken: "FAKE-1//0gb-XXXX",
            expiryDate: (now.timeIntervalSince1970 + 600) * 1000.0
        )
        let client = GeminiOAuthClient(
            http: http,
            credentialLoader: GeminiCredentialLoader(credentialsPath: credsURL),
            clock: VirtualClock(fixed: now)
        )

        // First call seeds cache from file (well above skew → no refresh).
        let first = try await client.freshAccessToken(now: now)
        #expect(String(describing: first) == "<redacted>")
        // Second call returns the cached value without hitting HTTP.
        _ = try await client.freshAccessToken(now: now)
        // No POSTs to oauth2/token; both calls served from cache or file.
        #expect(http.calls.isEmpty)
    }

    // MARK: - Test 2: Eager from-file skip — no refresh

    @Test func eagerFromFileHit_doesNotRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeGeminiHTTPClient()
        let credsURL = try writeCredsFile(
            accessToken: "FAKE-fromFile-AAAAA",
            refreshToken: "FAKE-1//0gb-XXXX",
            expiryDate: (now.timeIntervalSince1970 + 600) * 1000.0
        )
        let client = GeminiOAuthClient(
            http: http,
            credentialLoader: GeminiCredentialLoader(credentialsPath: credsURL),
            clock: VirtualClock(fixed: now)
        )

        let bearer = try await client.freshAccessToken(now: now)
        #expect(String(describing: bearer) == "<redacted>")
        #expect(http.calls.isEmpty)
    }

    // MARK: - Test 3: Expiry-imminent → refresh, then cache (60s skew)

    @Test func expiryImminent_refreshes_thenCachesSubsequentCalls() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeGeminiHTTPClient()
        http.postFormResponses = [.success(try loadFixtureData("gemini-token-refresh-fixture.json"))]
        let credsURL = try writeCredsFile(
            accessToken: "FAKE-stale-AAAA",
            refreshToken: "FAKE-1//0gb-EXPIRED",
            // 30s in the future — less than the 60s skew window.
            expiryDate: (now.timeIntervalSince1970 + 30) * 1000.0
        )
        let client = GeminiOAuthClient(
            http: http,
            credentialLoader: GeminiCredentialLoader(credentialsPath: credsURL),
            clock: VirtualClock(fixed: now)
        )

        let bearer = try await client.freshAccessToken(now: now)
        #expect(String(describing: bearer) == "<redacted>")
        #expect(http.calls.count == 1)

        // A subsequent call inside the skew window of the freshly refreshed
        // token reuses the cache (no second POST).
        _ = try await client.freshAccessToken(now: now)
        #expect(http.calls.count == 1)
    }

    // MARK: - Test 4: Refresh request body has correct shape

    @Test func refreshBody_isFormURLEncodedWithCorrectFields() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeGeminiHTTPClient()
        http.postFormResponses = [.success(try loadFixtureData("gemini-token-refresh-fixture.json"))]
        let refreshToken = "FAKE-1//0gb-Has Spaces&Specials"
        let credsURL = try writeCredsFile(
            accessToken: nil,
            refreshToken: refreshToken,
            expiryDate: 0
        )
        let client = GeminiOAuthClient(
            http: http,
            credentialLoader: GeminiCredentialLoader(credentialsPath: credsURL),
            clock: VirtualClock(fixed: now)
        )

        _ = try await client.freshAccessToken(now: now)

        let call = try #require(http.calls.first)
        #expect(call.url == GeminiOAuthClient.tokenURL)
        let body = try #require(call.formBody)
        #expect(body.contains("client_id=681255809395-"))
        #expect(body.contains("client_secret=GOCSPX-"))
        #expect(body.contains("grant_type=refresh_token"))
        // Percent-encoded refresh_token (space → %20, & → %26).
        let encoded = refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        #expect(body.contains("refresh_token=\(encoded ?? "")"))
        // Content-Type carried by the protocol contract — fake captures it.
        // The header dict normalises ordering; just confirm presence on the call.
        // (URLSessionHTTPClient sets it; the fake mirrors only the body.)
    }

    // MARK: - Test 5: Refresh 400 → refreshFailed(status: 400)

    @Test func refresh400_throwsRefreshFailed_400() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeGeminiHTTPClient()
        http.postFormResponses = [.failure(HTTPError(status: 400))]
        let credsURL = try writeCredsFile(
            accessToken: nil,
            refreshToken: "FAKE-1//0gb-XXXX",
            expiryDate: 0
        )
        let client = GeminiOAuthClient(
            http: http,
            credentialLoader: GeminiCredentialLoader(credentialsPath: credsURL),
            clock: VirtualClock(fixed: now)
        )
        await #expect(throws: GeminiOAuthError.refreshFailed(status: 400)) {
            _ = try await client.freshAccessToken(now: now)
        }
    }

    // MARK: - Test 6: Refresh 401 → refreshFailed(status: 401)

    @Test func refresh401_throwsRefreshFailed_401() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeGeminiHTTPClient()
        http.postFormResponses = [.failure(HTTPError(status: 401))]
        let credsURL = try writeCredsFile(
            accessToken: nil,
            refreshToken: "FAKE-1//0gb-XXXX",
            expiryDate: 0
        )
        let client = GeminiOAuthClient(
            http: http,
            credentialLoader: GeminiCredentialLoader(credentialsPath: credsURL),
            clock: VirtualClock(fixed: now)
        )
        await #expect(throws: GeminiOAuthError.refreshFailed(status: 401)) {
            _ = try await client.freshAccessToken(now: now)
        }
    }

    // MARK: - Test 7: Missing oauth_creds.json → notSignedIn (Pitfall 9)

    @Test func missingCredsFile_throwsNotSignedIn() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeGeminiHTTPClient()
        let missingURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nonexistent-gemini-\(UUID().uuidString).json")
        let client = GeminiOAuthClient(
            http: http,
            credentialLoader: GeminiCredentialLoader(credentialsPath: missingURL),
            clock: VirtualClock(fixed: now)
        )
        await #expect(throws: GeminiOAuthError.notSignedIn) {
            _ = try await client.freshAccessToken(now: now)
        }
    }

    // MARK: - Test 8: retryAfter401 invalidates cache and forces refresh

    @Test func retryAfter401_invalidatesCache_andForcesRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeGeminiHTTPClient()
        // First refresh seeds the cache; second refresh is the retry-after-401.
        http.postFormResponses = [
            .success(try loadFixtureData("gemini-token-refresh-fixture.json")),
            .success(try loadFixtureData("gemini-token-refresh-fixture.json")),
        ]
        let credsURL = try writeCredsFile(
            accessToken: nil,
            refreshToken: "FAKE-1//0gb-XXXX",
            expiryDate: 0
        )
        let client = GeminiOAuthClient(
            http: http,
            credentialLoader: GeminiCredentialLoader(credentialsPath: credsURL),
            clock: VirtualClock(fixed: now)
        )

        _ = try await client.freshAccessToken(now: now)
        #expect(http.calls.count == 1)
        // Without retryAfter401, a freshAccessToken call inside the 60s skew
        // window would reuse the cache (no second POST).
        _ = try await client.retryAfter401(now: now)
        #expect(http.calls.count == 2)
    }

    // MARK: - Test 9: D-10 invariant — file is byte-identical before and after a successful refresh

    @Test func successfulRefresh_doesNotWriteCredsFile() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeGeminiHTTPClient()
        http.postFormResponses = [.success(try loadFixtureData("gemini-token-refresh-fixture.json"))]
        let credsURL = try writeCredsFile(
            accessToken: nil,
            refreshToken: "FAKE-1//0gb-XXXX",
            expiryDate: 0
        )
        let before = try Data(contentsOf: credsURL)
        let client = GeminiOAuthClient(
            http: http,
            credentialLoader: GeminiCredentialLoader(credentialsPath: credsURL),
            clock: VirtualClock(fixed: now)
        )
        _ = try await client.freshAccessToken(now: now)
        let after = try Data(contentsOf: credsURL)
        #expect(before == after)
    }

    // MARK: - Test 10: Pitfall 10 static guard — refresh response struct has no refresh_token

    @Test func refreshResponseStruct_hasNoRefreshTokenField() throws {
        let repoRoot = repoRootFromTestFile()
        let url = repoRoot
            .appendingPathComponent("AgentsUsageBar/Providers/Gemini/Models/GeminiTokenRefreshResponse.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        // Strip block comments / line comments so the assertion ignores
        // doc-comment prose that mentions the field name as part of the
        // Pitfall 10 explanation.
        let stripped = stripComments(src)
        #expect(!stripped.contains("refresh_token"),
                "Pitfall 10: refresh response struct must not declare a refresh_token CodingKey")
        #expect(!stripped.contains("refreshToken"),
                "Pitfall 10: refresh response struct must not declare a refreshToken property")
    }

    // MARK: - Test 11: SEC-04 fixture grep — no real Google token shapes

    @Test func fixtures_doNotContainLiveGoogleTokenShapes() throws {
        let repoRoot = repoRootFromTestFile()
        let fixturesDir = repoRoot
            .appendingPathComponent("AgentsUsageBarTests/ProvidersGeminiTests/Fixtures")
        let files = try FileManager.default.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
        for file in files {
            let body = try String(contentsOf: file, encoding: .utf8)
            // RFC 6749 §2.1: the literal client_secret is OK in production
            // source. Fixtures, however, must use FAKE- prefixes.
            #expect(!body.contains("GOCSPX-4uHg"),
                    "Fixture \(file.lastPathComponent) carries the real client_secret prefix")
            // ya29. is Google's standard access_token prefix.
            #expect(!body.contains("\"ya29."),
                    "Fixture \(file.lastPathComponent) carries an unmasked ya29 access_token prefix")
        }
    }

    // MARK: - Test 12: ci.yml SEC-04 exclusion includes GeminiOAuthClient.swift

    @Test func ciYamlSEC04_excludesGeminiOAuthClient() throws {
        let repoRoot = repoRootFromTestFile()
        let url = repoRoot.appendingPathComponent(".github/workflows/ci.yml")
        let src = try String(contentsOf: url, encoding: .utf8)
        #expect(src.contains("GeminiOAuthClient.swift"),
                "ci.yml must add --exclude='GeminiOAuthClient.swift' so the RFC 6749 §2.1 client_secret constant doesn't trip SEC-04")
    }

    // MARK: - Test 13: CR-02 — retryAfter401 forces a POST even when the
    // on-disk file still holds the rejected access_token (stuck-loop guard).

    @Test func retryAfter401_forcesRefresh_evenWhenDiskHoldsRejectedToken() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeGeminiHTTPClient()
        // Only the retry POST is scripted — the first freshAccessToken should
        // serve from the disk fast-path with zero HTTP calls.
        http.postFormResponses = [.success(try loadFixtureData("gemini-token-refresh-fixture.json"))]

        let staleToken = "FAKE-stale-AAAAA"
        let credsURL = try writeCredsFile(
            // Both the file's accessToken AND its expiry are valid — the bug
            // CR-02 protected against was retryAfter401 re-seeding this same
            // value back from disk after the caller saw it rejected.
            accessToken: staleToken,
            refreshToken: "FAKE-1//0gb-XXXX",
            expiryDate: (now.timeIntervalSince1970 + 600) * 1000.0
        )
        let client = GeminiOAuthClient(
            http: http,
            credentialLoader: GeminiCredentialLoader(credentialsPath: credsURL),
            clock: VirtualClock(fixed: now)
        )

        // 1. First fetch hits the disk fast-path — zero POSTs.
        _ = try await client.freshAccessToken(now: now)
        #expect(http.calls.isEmpty)

        // 2. Caller sees 401 → retryAfter401 must fire a POST oauth2/token,
        // NOT re-seed the same staleToken from disk.
        _ = try await client.retryAfter401(now: now)
        #expect(http.calls.count == 1)
        let postCall = try #require(http.calls.first)
        #expect(postCall.url == GeminiOAuthClient.tokenURL)
        #expect(postCall.method == "POST")

        // 3. A follow-up freshAccessToken call (still inside the skew window
        // of the freshly refreshed token) serves from cache — no extra POST.
        _ = try await client.freshAccessToken(now: now)
        #expect(http.calls.count == 1)
    }

    // MARK: - Helpers

    private func repoRootFromTestFile() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("AgentsUsageBar.xcodeproj")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    private func stripComments(_ source: String) -> String {
        var out = ""
        var inBlockComment = false
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for raw in lines {
            var line = raw
            // Strip block comments line-by-line. (Naive but sufficient for
            // this single-file static check.)
            if inBlockComment {
                if let close = line.range(of: "*/") {
                    line = String(line[close.upperBound...])
                    inBlockComment = false
                } else {
                    continue
                }
            }
            while let open = line.range(of: "/*") {
                if let close = line.range(of: "*/", range: open.upperBound..<line.endIndex) {
                    line.removeSubrange(open.lowerBound..<close.upperBound)
                } else {
                    line = String(line[..<open.lowerBound])
                    inBlockComment = true
                    break
                }
            }
            // Strip line comments.
            if let lc = line.range(of: "//") {
                line = String(line[..<lc.lowerBound])
            }
            out.append(line)
            out.append("\n")
        }
        return out
    }
}

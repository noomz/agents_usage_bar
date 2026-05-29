import Foundation
import os.log

// MARK: - ClaudeOAuthError

/// Errors surfaced by `ClaudeOAuthClient`.
///
/// `usageEndpointFailed(status: 429)` is a sentinel value — Plan 02.06's circuit
/// breaker trips after 3 consecutive 429s on this endpoint (Pitfall 5, RESEARCH §A.1).
/// Callers should check `status == 429` to apply circuit-break logic.
public enum ClaudeOAuthError: Error, Sendable, Equatable {
    /// No credentials could be resolved from file, Keychain, or environment.
    case noCredentials
    /// The token refresh POST failed. `message` carries a diagnostic hint.
    case refreshFailed(message: String)
    /// The usage GET returned a non-2xx status.
    /// - `status: 429` — persistent on Claude Max plans (Pitfall 5); Plan 02.06 wraps this.
    case usageEndpointFailed(status: Int)
}

// MARK: - ClaudeCredentialResolver

/// Protocol seam allowing `ClaudeOAuthClient` tests to inject a fake credential loader.
///
/// `ClaudeCredentialLoader` is the production conformer (via extension below).
public protocol ClaudeCredentialResolver: Sendable {
    func loadCredentials() -> ClaudeCredentialLoader.Result?
    func needsRefresh(_ o: ClaudeCredentialLoader.OAuth, now: Date, refreshBufferMs: Double) -> Bool
    func saveCredentials(_ oauth: ClaudeCredentialLoader.OAuth, to source: ClaudeCredentialLoader.Source) throws
}

extension ClaudeCredentialLoader: ClaudeCredentialResolver {}

// MARK: - ClaudeOAuthClient

/// Performs the Anthropic OAuth lifecycle:
/// 1. Load credentials (file → Keychain → env).
/// 2. If token is near-expiry AND a refresh token exists, POST to the refresh endpoint.
/// 3. Write back the rotated tokens (SEC-NOTE — default decision #1).
/// 4. GET the usage endpoint with the fresh access token.
///
/// Source: verified against ClaudeBar/Sources/Infrastructure/Claude/ClaudeAPIUsageProbe.swift
/// + GitHub issue #30930 (persistent 429 caveat) + codelynx.dev/posts/claude-code-usage-limits.
///
/// SEC-01: The access token is wrapped in `Secret` immediately before passing to
/// `http.get`. `revealForRequest()` is NOT called here — only inside
/// `URLSessionHTTPClient.performGet`.
public actor ClaudeOAuthClient {

    // MARK: - Public constants

    /// Usage endpoint — RESEARCH §B.1 verified.
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Token refresh endpoint — RESEARCH §B.1 verified (ClaudeBar source).
    public static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /// Required beta header value for the usage endpoint.
    public static let oauthBetaHeader = "oauth-2025-04-20"

    /// OAuth client_id — verified against ClaudeBar source (RESEARCH §B.1).
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    // MARK: - Private

    private let http: any HTTPClient
    private let credentials: any ClaudeCredentialResolver
    private let clock: any Clock
    private let logger = AppLogger.logger(category: "oauth")

    // MARK: - Init

    /// - Parameters:
    ///   - http: Shared URLSession-backed HTTP client (POLL-08 singleton invariant).
    ///   - credentials: Credential resolver (default: `ClaudeCredentialLoader()`).
    ///   - clock: Clock abstraction for testable time-based refresh decisions.
    public init(
        http: any HTTPClient,
        credentials: any ClaudeCredentialResolver = ClaudeCredentialLoader(),
        clock: any Clock = SystemClock()
    ) {
        self.http = http
        self.credentials = credentials
        self.clock = clock
    }

    // MARK: - Public API

    /// Fetches today's quota utilization from the Anthropic OAuth usage endpoint.
    ///
    /// Algorithm:
    /// 1. Load credentials — throws `.noCredentials` if none found.
    /// 2. If token needs refresh AND a refresh token exists, call `refreshAccessToken`.
    ///    Write back rotated tokens (fire-and-forget `try?` — SEC-NOTE).
    /// 3. Wrap access token in `Secret` (SEC-01).
    /// 4. GET usage endpoint with `anthropic-beta` header.
    ///
    /// - Throws: `ClaudeOAuthError` for auth/refresh/HTTP failures.
    public func getUsage() async throws -> ClaudeUsageResponse {
        guard var credResult = credentials.loadCredentials() else {
            throw ClaudeOAuthError.noCredentials
        }

        // Step 2: Refresh if near-expiry AND refresh token exists.
        let now = clock.now()
        if credentials.needsRefresh(credResult.oauth, now: now, refreshBufferMs: 5 * 60 * 1000),
           let refreshToken = credResult.oauth.refreshToken
        {
            do {
                let refreshed = try await refreshAccessToken(refreshToken: refreshToken)

                // Build updated OAuth — preserve subscriptionType (not returned on refresh).
                var newOAuth = credResult.oauth
                newOAuth.accessToken = refreshed.accessToken
                newOAuth.refreshToken = refreshed.refreshToken ?? newOAuth.refreshToken
                if let expiresIn = refreshed.expiresIn {
                    newOAuth.expiresAt = now.timeIntervalSince1970 * 1000 + expiresIn * 1000
                }
                credResult = ClaudeCredentialLoader.Result(oauth: newOAuth, source: credResult.source)

                // SEC-NOTE write-back (default decision #1 — mirror ClaudeBar precedent).
                // Fire-and-forget: a transient Keychain ACL error must never block the fetch.
                try? credentials.saveCredentials(newOAuth, to: credResult.source)
                logger.notice("oauth: token refreshed and written back to \(String(describing: credResult.source), privacy: .public)")
            } catch let err as ClaudeOAuthError {
                throw err
            }
        }

        // Step 3: Wrap in Secret immediately (SEC-01).
        let bearer = Secret(credResult.oauth.accessToken)

        // Step 4: GET usage endpoint.
        do {
            return try await http.get(
                Self.usageURL,
                bearer: bearer,
                extraHeaders: [
                    "anthropic-beta": Self.oauthBetaHeader,
                    "Accept": "application/json",
                    "User-Agent": "Agents-Usage-Bar/1.0",
                ],
                as: ClaudeUsageResponse.self
            )
        } catch let httpErr as HTTPError {
            // Pitfall 5 (RESEARCH §A.1): 429 on this endpoint is persistent for Claude Max.
            // Surface as a distinct error type so Plan 02.06's circuit breaker can identify it.
            throw ClaudeOAuthError.usageEndpointFailed(status: httpErr.status)
        }
    }

    // MARK: - Private

    /// Posts to the OAuth token refresh endpoint.
    ///
    /// Body: `{"grant_type":"refresh_token","refresh_token":<token>,"client_id":<id>}`
    /// Encoded with `.convertToSnakeCase` via `URLSessionHTTPClient.postJSON`.
    ///
    /// SEC-02: The body is never logged — `URLSessionHTTPClient.postJSON` logs path+status only.
    private func refreshAccessToken(refreshToken: String) async throws -> ClaudeTokenRefreshResponse {
        let body = RefreshBody(
            grantType: "refresh_token",
            refreshToken: refreshToken,
            clientId: Self.clientID
        )
        do {
            return try await http.postJSON(
                Self.refreshURL,
                body: body,
                extraHeaders: [
                    "Accept": "application/json",
                    "User-Agent": "Agents-Usage-Bar/1.0",
                ],
                as: ClaudeTokenRefreshResponse.self
            )
        } catch let httpErr as HTTPError {
            // T-02.03-07: surface an actionable hint for invalid_client (RESEARCH §A1).
            let hint = httpErr.status == 400 || httpErr.status == 401
                ? "invalid_client (run 'claude logout && claude login')"
                : "HTTP \(httpErr.status)"
            throw ClaudeOAuthError.refreshFailed(message: "refresh failed: \(hint)")
        }
    }
}

// MARK: - Private helpers

/// Body struct for the token refresh POST request.
/// Encoded with `JSONEncoder.keyEncodingStrategy = .convertToSnakeCase`:
///   `grantType` → `grant_type`, `refreshToken` → `refresh_token`, `clientId` → `client_id`.
private struct RefreshBody: Encodable, Sendable {
    let grantType: String
    let refreshToken: String
    let clientId: String
}

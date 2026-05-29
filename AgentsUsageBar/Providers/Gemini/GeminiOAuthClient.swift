import Foundation
import os.log

// MARK: - GeminiOAuthClient
//
// Performs the Gemini OAuth-personal credential lifecycle:
//   1. Resolve credentials from `~/.gemini/oauth_creds.json`.
//   2. **Eager pre-check (D-09):** if the cached access_token (or the one
//      already on disk) is more than 60 seconds away from expiry, use it
//      without contacting Google.
//   3. **Lazy 401 catch (D-09):** if a downstream call (Plan 03-06)
//      returns 401, invalidate the cache and force one fresh refresh.
//   4. **In-memory only (D-10):** refreshed access_token + computed
//      expiry NEVER written back to `~/.gemini/oauth_creds.json` —
//      gemini-cli owns that file; we are read-only.
//
// Pitfall 10 invariant: this client does NOT decode a `refresh_token`
// from the refresh response and does NOT overwrite the on-disk
// refresh_token with anything (the response struct deliberately omits
// the field — see GeminiTokenRefreshResponse).
//
// SEC-01 invariant: this file MUST NOT call the credential-reveal accessor.
// `Secret` wrapping happens at `URLRequest` Authorization-header construction
// inside `URLSessionHTTPClient.performGet` (Phase 1 STATE #15). The refresh
// body itself percent-encodes the refresh_token plain text — that is
// inherent to OAuth2 form-urlencoded grants and does not pass through the
// `Secret` reveal accessor.
//
// **Client credentials sourcing (RFC 6749 §2.1):** the OAuth2 spec treats
// `client_secret` as publicly accessible for installed-app flows, but
// GitHub push-protection scanners still flag the literal strings. The
// gemini-cli `client_id` / `client_secret` are therefore NOT embedded in
// source — the caller injects them via `GeminiCLIPublicCreds` resolved
// from environment variables (`GEMINI_CLI_CLIENT_ID`,
// `GEMINI_CLI_CLIENT_SECRET`). When the caller passes `nil`, refresh is
// disabled and the cached / on-disk access token is used until it
// expires; expired tokens surface as `.refreshDisabled` which the
// provider renders as the same degraded UX as `.refreshFailed`.
// See `docs/gemini-setup.md` for the values published by gemini-cli.

/// Caller-supplied gemini-cli OAuth2 client credentials. Values come from
/// gemini-cli's `oauth2.ts` (see `docs/gemini-setup.md`); resolution lives
/// outside this file so the literal strings stay out of git history.
public struct GeminiCLIPublicCreds: Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Resolve from a `ProcessInfo.environment`-shaped dictionary.
    /// Returns nil when either variable is missing or empty so callers
    /// can fall back to the degraded-UX branch without throwing.
    public static func fromEnvironment(_ env: [String: String]) -> GeminiCLIPublicCreds? {
        guard let cid = env["GEMINI_CLI_CLIENT_ID"], !cid.isEmpty,
              let cs = env["GEMINI_CLI_CLIENT_SECRET"], !cs.isEmpty
        else { return nil }
        return GeminiCLIPublicCreds(clientID: cid, clientSecret: cs)
    }
}

/// Actor managing the eager-pre-check + lazy-401 OAuth state machine for
/// Gemini. Refreshed access_token is kept in actor-isolated state only.
public actor GeminiOAuthClient {

    // MARK: - Public constants

    /// Google's OAuth2 token endpoint (form-urlencoded grants).
    public static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    /// Skew window for the eager pre-check (seconds). If the token expires
    /// within this window we refresh proactively.
    public static let refreshSkewSeconds: TimeInterval = 60

    // MARK: - Private

    private let http: any HTTPClient
    private let credentialLoader: GeminiCredentialLoader
    private let clock: any Clock
    private let publicCreds: GeminiCLIPublicCreds?
    private let logger = AppLogger.logger(category: "gemini-oauth")

    /// In-memory cache of the most recent successful access_token.
    private var cachedAccessToken: String?

    /// In-memory cache of the computed expiry for the cached access_token.
    private var cachedExpiryDate: Date?

    /// Diagnostics-only mirror of the last refresh_token observed on disk.
    /// Never used as a bearer; never logged.
    private var lastRefreshTokenSeen: String?

    /// The most recent access_token a downstream caller saw rejected with 401.
    /// `freshAccessToken(now:)` STEP 3 will skip the on-disk fast-path when the
    /// file still holds this exact value — otherwise `retryAfter401` would just
    /// re-seed the same rejected bearer from disk and lock callers into a
    /// stuck `.error(401)` loop until `oauth_creds.json` mtime changes (CR-02).
    /// Cleared after a successful POST oauth2.googleapis.com/token.
    private var lastRejectedAccessToken: String?

    // MARK: - Init

    /// - Parameters:
    ///   - http: Shared URLSession-backed HTTP client (POLL-08 singleton).
    ///   - credentialLoader: `~/.gemini/oauth_creds.json` resolver.
    ///   - clock: Clock abstraction for deterministic eager-skew tests.
    ///   - publicCreds: gemini-cli OAuth2 client credentials. `nil` disables
    ///     the in-app refresh path; cached and on-disk access tokens are
    ///     still used until they expire, after which `freshAccessToken`
    ///     throws `.refreshDisabled` and the provider renders the same
    ///     degraded UX as `.refreshFailed`.
    public init(
        http: any HTTPClient,
        credentialLoader: GeminiCredentialLoader = GeminiCredentialLoader(),
        clock: any Clock = SystemClock(),
        publicCreds: GeminiCLIPublicCreds? = nil
    ) {
        self.http = http
        self.credentialLoader = credentialLoader
        self.clock = clock
        self.publicCreds = publicCreds
    }

    // MARK: - Public API

    /// Returns a fresh bearer wrapped in `Secret`, refreshing if the
    /// 60 second skew window is crossed.
    ///
    /// State machine (D-09):
    ///   1. Eager cache hit: `cachedExpiryDate - now > 60s` → reuse.
    ///   2. Eager from-file hit: file has access_token AND
    ///      `expiry - now > 60s` → seed cache + reuse.
    ///   3. Refresh: POST oauth2.googleapis.com/token with the on-disk
    ///      refresh_token; cache the new access_token + expiry.
    public func freshAccessToken(now: Date) async throws -> Secret {

        // STEP 1: Eager pre-check against actor-cached token.
        if let cached = cachedAccessToken,
           let expiry = cachedExpiryDate,
           expiry.timeIntervalSince(now) > Self.refreshSkewSeconds
        {
            return Secret(cached)
        }

        // STEP 2: Resolve on-disk credentials. Missing file → Pitfall 9.
        guard let result = credentialLoader.loadCredentials() else {
            throw GeminiOAuthError.notSignedIn
        }
        lastRefreshTokenSeen = result.credentials.refreshToken

        // STEP 3: Eager pre-check against the file's cached access_token.
        // Skip if this exact token was just rejected with 401 — otherwise
        // retryAfter401 would re-seed the same bearer from disk (CR-02).
        if let fileAccess = result.credentials.accessToken,
           !fileAccess.isEmpty,
           fileAccess != lastRejectedAccessToken
        {
            let fileExpiry = result.credentials.expiryDateAsDate()
            if fileExpiry.timeIntervalSince(now) > Self.refreshSkewSeconds {
                cachedAccessToken = fileAccess
                cachedExpiryDate = fileExpiry
                return Secret(fileAccess)
            }
        }

        // STEP 4: Refresh.
        let refreshed = try await performRefresh(
            refreshToken: result.credentials.refreshToken,
            now: now
        )
        cachedAccessToken = refreshed.accessToken
        cachedExpiryDate = refreshed.expiryDate
        // A successful refresh supersedes any prior 401-rejected bearer.
        lastRejectedAccessToken = nil
        return Secret(refreshed.accessToken)
    }

    /// Lazy 401 catch: records the rejected bearer so the next
    /// `freshAccessToken(now:)` skips the on-disk fast-path and forces a
    /// fresh POST oauth2.googleapis.com/token, even if the file still
    /// contains the same access_token (CR-02). Callers in Plan 03-06 must
    /// enforce at-most-one retry per high-level request.
    public func retryAfter401(now: Date) async throws -> Secret {
        // Capture whichever bearer the caller saw rejected — cache first,
        // then fall back to whatever is currently on disk.
        if let cached = cachedAccessToken {
            lastRejectedAccessToken = cached
        } else if let fileAccess = credentialLoader.loadCredentials()?.credentials.accessToken,
                  !fileAccess.isEmpty
        {
            lastRejectedAccessToken = fileAccess
        }
        cachedAccessToken = nil
        cachedExpiryDate = nil
        return try await freshAccessToken(now: now)
    }

    // MARK: - Private

    /// Posts to Google's OAuth2 token endpoint with form-encoded credentials.
    /// On 200, returns the new access_token + absolute expiry Date.
    /// On non-2xx, throws `.refreshFailed(status:)`.
    private func performRefresh(
        refreshToken: String,
        now: Date
    ) async throws -> (accessToken: String, expiryDate: Date) {
        guard let creds = publicCreds else {
            logger.notice("oauth2/token refresh skipped — GEMINI_CLI_CLIENT_ID / GEMINI_CLI_CLIENT_SECRET not set")
            throw GeminiOAuthError.refreshDisabled
        }
        do {
            let response: GeminiTokenRefreshResponse = try await http.postFormURLEncoded(
                Self.tokenURL,
                formFields: [
                    ("client_id", creds.clientID),
                    ("client_secret", creds.clientSecret),
                    ("refresh_token", refreshToken),
                    ("grant_type", "refresh_token"),
                ],
                extraHeaders: [
                    "Accept": "application/json",
                    "User-Agent": "Agents-Usage-Bar/1.0",
                ],
                as: GeminiTokenRefreshResponse.self
            )
            // SEC-02: log only the status-bearing path; never the body.
            logger.notice("oauth2/token refresh OK")
            let expiry = Date(timeIntervalSince1970:
                now.timeIntervalSince1970 + Double(response.expiresIn))
            // D-10: returned `accessToken` and `expiry` are STORED IN
            // ACTOR MEMORY ONLY by the caller. No file write here.
            return (response.accessToken, expiry)
        } catch let httpErr as HTTPError {
            logger.notice("oauth2/token \(httpErr.status, privacy: .public) — refresh failed")
            throw GeminiOAuthError.refreshFailed(status: httpErr.status)
        } catch {
            throw GeminiOAuthError.transport(underlying: error)
        }
    }
}

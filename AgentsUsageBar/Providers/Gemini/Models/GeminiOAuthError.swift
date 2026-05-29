import Foundation

// MARK: - GeminiOAuthError
//
// Errors surfaced by `GeminiOAuthClient`.

/// Typed-error surface for the Gemini OAuth credential + refresh path.
///
/// Disposition guidance for the downstream `GeminiOAuthProvider` (Plan 03-06):
/// - `.noCredentials` / `.notSignedIn` — Pitfall 9; render muted "No data yet"
///   row (D-03 convention).
/// - `.settingsGateClosed` — settings.json says something other than
///   `oauth-personal`; provider should not register / fetch at all (Plan 03-06
///   composition root skips it). Reserved for completeness.
/// - `.refreshFailed(status:)` — non-2xx from `oauth2.googleapis.com/token`;
///   feeds AggregateStore-level CircuitBreaker (POLL-05).
/// - `.transport(underlying:)` — network / DecodingError / non-`HTTPError`
///   failures bubbled from the HTTP layer.
public enum GeminiOAuthError: Error, Sendable {

    /// `~/.gemini/oauth_creds.json` is absent or unusable.
    /// Functionally synonymous with `.notSignedIn` in v1; both yield the
    /// muted "No data yet" row.
    case noCredentials

    /// `settings.json` does NOT have `security.auth.selectedType == "oauth-personal"`.
    /// Reserved for completeness — the composition root usually catches this
    /// before the client is ever called.
    case settingsGateClosed

    /// Non-2xx from the OAuth token endpoint.
    case refreshFailed(status: Int)

    /// gemini-cli OAuth2 client credentials (`GEMINI_CLI_CLIENT_ID` /
    /// `GEMINI_CLI_CLIENT_SECRET`) are not configured, so the in-app
    /// refresh path is disabled. Cached + on-disk access tokens still
    /// flow; this only fires when those are also expired. Rendered as
    /// the same degraded UX as `.refreshFailed` (D-11).
    case refreshDisabled

    /// `oauth_creds.json` was absent while `settings.json` said `oauth-personal`
    /// (Pitfall 9 — keychain migration).
    case notSignedIn

    /// Transport / decode / non-HTTPError failure from the request path.
    case transport(underlying: Error)
}

extension GeminiOAuthError: Equatable {
    public static func == (lhs: GeminiOAuthError, rhs: GeminiOAuthError) -> Bool {
        switch (lhs, rhs) {
        case (.noCredentials, .noCredentials),
             (.settingsGateClosed, .settingsGateClosed),
             (.refreshDisabled, .refreshDisabled),
             (.notSignedIn, .notSignedIn):
            return true
        case (.refreshFailed(let a), .refreshFailed(let b)):
            return a == b
        case (.transport, .transport):
            // Underlying Error is not generally Equatable; treat any two
            // transport errors as equal for assertion convenience.
            return true
        default:
            return false
        }
    }
}

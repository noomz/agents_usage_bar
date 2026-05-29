import Foundation

// MARK: - GeminiOAuthCredentials
//
// RESEARCH correction #3:
//   `expiry_date` is **epoch MILLISECONDS** as a FLOAT (verified from live
//   `~/.gemini/oauth_creds.json`). Divide by 1000.0 to obtain a Swift
//   `TimeInterval`.
//
// IMPORTANT: do NOT confuse with Codex `reset_at` / rollout `resets_at`,
// which are epoch SECONDS (no divide). Both providers live in the same
// codebase — the unit difference is the load-bearing distinction.
//
// Verified shape (RESEARCH §"Gemini oauth_creds.json Schema"):
// ```
// {
//   "access_token": "ya29.a0A...",
//   "refresh_token": "1//0gb...",
//   "scope": "https://www.googleapis.com/auth/...",
//   "id_token": "eyJhbGci...",
//   "expiry_date": 1778834115287.89,
//   "token_type": "Bearer"
// }
// ```
//
// `accessToken` is OPTIONAL — gemini-cli may clear it after a failed refresh
// while preserving `refresh_token`. `refreshToken` is non-optional: without
// it the OAuth client cannot operate, so JSONDecoder will throw and the
// loader returns nil (treated as "no usable creds").

/// Decoded shape of `~/.gemini/oauth_creds.json` written by gemini-cli.
public struct GeminiOAuthCredentials: Decodable, Sendable, Equatable {

    /// Cached access_token from the last successful refresh. May be nil if
    /// gemini-cli cleared it (the file then carries only refresh_token +
    /// expiry_date until the next interactive `gemini` invocation).
    public let accessToken: String?

    /// Long-lived refresh token. Google does NOT rotate this (Pitfall 10).
    public let refreshToken: String

    /// OAuth scope string (informational; not consumed by v1).
    public let scope: String?

    /// JWT identity token (informational; not consumed by v1).
    public let idToken: String?

    /// Epoch MILLISECONDS as a Double (RESEARCH correction #3). Divide by
    /// 1000.0 — `expiryDateAsDate()` does this for you.
    public let expiryDate: Double

    /// Always `"Bearer"` in practice; carried for symmetry.
    public let tokenType: String?

    // Explicit snake_case CodingKeys — never rely on a global
    // `keyDecodingStrategy = .convertFromSnakeCase` (mirrors Phase 2
    // TranscriptRecord + Phase 3 CodexRolloutEvent / CodexUsageResponse).
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case scope
        case idToken = "id_token"
        case expiryDate = "expiry_date"
        case tokenType = "token_type"
    }

    /// Converts `expiryDate` (epoch ms) to a Swift `Date`.
    ///
    /// Implementation: `Date(timeIntervalSince1970: expiryDate / 1000.0)`
    /// — RESEARCH correction #3.
    public func expiryDateAsDate() -> Date {
        Date(timeIntervalSince1970: expiryDate / 1000.0)
    }
}

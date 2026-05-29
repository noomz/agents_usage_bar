import Foundation

// MARK: - GeminiTokenRefreshResponse
//
// Response from `POST https://oauth2.googleapis.com/token` (refresh grant).
//
// Pitfall 10 invariant: this struct intentionally has NO `refresh_token`
// field. Google does NOT rotate the refresh_token on installed-app refresh
// grants; if a future response contains one we ignore it. Adding a field
// here would invite accidental writes back into in-memory state.
//
// Source: RESEARCH §"Gemini OAuth Refresh" response example.

/// Successful refresh response from Google's OAuth2 token endpoint.
public struct GeminiTokenRefreshResponse: Decodable, Sendable, Equatable {

    /// The new bearer for `cloudcode-pa.googleapis.com` calls.
    public let accessToken: String

    /// Lifetime of `accessToken` in SECONDS. Compose absolute expiry as:
    /// `Date(timeIntervalSince1970: now.timeIntervalSince1970 + Double(expiresIn))`.
    public let expiresIn: Int

    public let tokenType: String?
    public let scope: String?
    public let idToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
        case idToken = "id_token"
    }
}

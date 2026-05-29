import Foundation

/// Decoded response from `GET https://api.anthropic.com/api/oauth/usage`.
///
/// Fields decoded with `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`:
///   `five_hour` → `fiveHour`, `seven_day_sonnet` → `sevenDaySonnet`, etc.
///
/// All top-level fields are optional — partial responses (e.g. only `five_hour`
/// present) are valid. Plan 02.04 normalises `QuotaWindowResponse.utilization`
/// from the API's 0–100 percentage to the Domain layer's 0.0–1.0 fraction.
///
/// Source: RESEARCH §B.2 — verified response shape.
public struct ClaudeUsageResponse: Decodable, Sendable, Equatable {

    /// The 5-hour rolling quota window (present for Claude Max plans).
    public let fiveHour: QuotaWindowResponse?

    /// The 7-day rolling quota window.
    public let sevenDay: QuotaWindowResponse?

    /// The 7-day rolling quota window scoped to Sonnet models.
    public let sevenDaySonnet: QuotaWindowResponse?

    /// The 7-day rolling quota window scoped to Opus models.
    public let sevenDayOpus: QuotaWindowResponse?

    /// A single quota window as returned by the Anthropic usage endpoint.
    public struct QuotaWindowResponse: Decodable, Sendable, Equatable {

        /// Utilization expressed as a 0–100 percentage.
        /// Plan 02.04 normalises this to [0.0, 1.0] before building a `QuotaWindow`.
        public let utilization: Double?

        /// ISO8601 timestamp at which the window resets,
        /// e.g. `"2026-05-13T20:00:00.000+00:00"`.
        public let resetsAt: String?
    }
}

/// Decoded response from `POST https://platform.claude.com/v1/oauth/token`.
///
/// Anthropic may or may not rotate the refresh token on each grant.
/// `refreshToken` is optional — when absent, the caller should preserve the
/// existing refresh token.
///
/// `expiresIn` is in **seconds** (OAuth2 standard). The caller computes:
///   `expiresAt = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000`
///
/// Source: RESEARCH §B.1 + OAuth2 RFC 6749 §5.1.
public struct ClaudeTokenRefreshResponse: Decodable, Sendable, Equatable {

    /// The new access token.
    public let accessToken: String

    /// The new refresh token, if Anthropic rotated it. Preserve old token when nil.
    public let refreshToken: String?

    /// Lifetime of the new access token in **seconds**.
    public let expiresIn: Double?
}

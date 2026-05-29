import Foundation

// MARK: - Credits Response

/// Response from `GET /api/v1/credits`.
///
/// Verified against https://openrouter.ai/docs/api/api-reference/credits/get-credits (2026-05-11).
/// Decoded with `keyDecodingStrategy = .convertFromSnakeCase`:
///   `total_credits` → `totalCredits`, `total_usage` → `totalUsage`.
public struct OpenRouterCreditsResponse: Decodable, Sendable, Equatable {
    public let data: Payload

    public struct Payload: Decodable, Sendable, Equatable {
        /// Lifetime credits purchased (USD). Balance = `totalCredits − totalUsage`.
        public let totalCredits: Double

        /// Lifetime cumulative spend (USD). Used as the baseline-delta source for D-01.
        public let totalUsage: Double
    }
}

// MARK: - Key Response

/// Response from `GET /api/v1/key`.
///
/// Verified against https://openrouter.ai/docs/api/reference/limits (2026-05-11).
/// Decoded with `keyDecodingStrategy = .convertFromSnakeCase`.
public struct OpenRouterKeyResponse: Decodable, Sendable, Equatable {
    public let data: Payload

    public struct Payload: Decodable, Sendable, Equatable {

        /// Human-readable label for the API key.
        public let label: String

        /// Monthly credit cap in USD.
        ///
        /// nil means the account has no quota cap (unlimited). Per D-14 / ROUTER-03,
        /// UI renders "no limit" gray bar instead of red; ThresholdEngine receives
        /// `quota == nil` and emits no decision.
        public let limit: Double?

        /// Date/time string when the limit resets; nil if it never resets or is not set.
        public let limitReset: String?

        /// Credits remaining before the cap is reached; nil for unlimited accounts.
        public let limitRemaining: Double?

        /// Whether BYOK (Bring Your Own Key) usage counts toward the limit.
        public let includeByokInLimit: Bool

        // MARK: Usage breakdown (all in USD)

        /// Lifetime cumulative spend. Used as baseline-delta source (D-01).
        public let usage: Double

        /// Current UTC-day spend. NOTE: Do NOT use for local-midnight "today" — timezone mismatch (D-01 clarification in RESEARCH.md).
        public let usageDaily: Double

        /// Current UTC-week spend.
        public let usageWeekly: Double

        /// Current UTC-month spend.
        public let usageMonthly: Double

        // MARK: BYOK usage

        public let byokUsage: Double
        public let byokUsageDaily: Double
        public let byokUsageWeekly: Double
        public let byokUsageMonthly: Double

        // MARK: Account tier

        /// `true` for free-tier accounts with rate-limited access.
        public let isFreeTier: Bool
    }
}

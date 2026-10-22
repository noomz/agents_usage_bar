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
        /// nil means the API key itself has no monthly cap. Per D-14 / ROUTER-03,
        /// a nil limit routes quota to the prepaid-credits fallback (`OpenRouterCreditsResponse.Payload.totalCredits`
        /// / `totalUsage`) instead. ThresholdEngine still sees `quota == nil` — and the UI
        /// still renders the "no limit" gray bar — only when credits are unavailable too
        /// (no purchase yet, or a zero/negative balance).
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

// MARK: - Activity Response

/// Response from `GET /api/v1/activity`: one item per UTC date, model, and endpoint.
///
/// Verified against https://openrouter.ai/openapi.json `ActivityItem` (2026-10-22).
/// Decoded with `keyDecodingStrategy = .convertFromSnakeCase`. Only the fields backfill
/// reads are declared.
public struct OpenRouterActivityResponse: Decodable, Sendable, Equatable {
    public let data: [Item]

    public struct Item: Decodable, Sendable, Equatable {
        /// UTC date, `YYYY-MM-DD`.
        public let date: String
        /// OpenRouter credits spent (USD). BYOK spend is separate and not included.
        public let usage: Decimal
        public let promptTokens: Int
        public let completionTokens: Int
    }
}

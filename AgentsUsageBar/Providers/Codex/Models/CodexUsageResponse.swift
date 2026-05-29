import Foundation

/// Decoded response from `GET https://chatgpt.com/backend-api/wham/usage`.
///
/// **CRITICAL (RESEARCH correction #5):** This schema is **deliberately distinct**
/// from `CodexRolloutEvent.RateLimits` (the local rollout JSONL shape). The
/// wham/usage endpoint uses **singular `rate_limit`** with **`primary_window` /
/// `secondary_window`** + **`reset_at`** (no `s`) + **`limit_window_seconds`**
/// (NOT `window_minutes`). The rollout shape uses the plural rate-limits
/// container, bare `primary`, and a different window-units field. The two
/// structs are intentionally kept separate — co-locating them would invite the
/// correction #5 mistake to silently re-enter the codebase.
///
/// Verified shape (RESEARCH §"Codex OAuth Fallback"):
/// ```json
/// {
///   "plan_type": "plus",
///   "rate_limit": {
///     "primary_window":   { "used_percent": 48, "reset_at": 1777970900, "limit_window_seconds": 18000 },
///     "secondary_window": { "used_percent": 26, "reset_at": 1778060488, "limit_window_seconds": 604800 }
///   },
///   "credits": { "has_credits": false, "unlimited": false, "balance": null }
/// }
/// ```
///
/// **Lenient by default (CLAUDE-03 / Pitfall 7):** Every field is optional with
/// `decodeIfPresent` semantics. Unknown keys are silently dropped (Phase 2
/// `TranscriptRecord` + `CodexRolloutEvent` precedent — `JSONDecoder` already
/// ignores undeclared keys). No `extraFields` / `AnyCodable` scaffolding.
public struct CodexUsageResponse: Decodable, Sendable, Equatable {

    /// Plan label — `"plus"`, `"pro"`, `"team"`, `"enterprise"`, etc. Surfaced
    /// via UI-11 `plan_type` tooltip (Phase 3 D-15).
    public let planType: String?

    /// Primary + secondary rate-limit windows. Either may be omitted for
    /// accounts in unusual states (brand-new, suspended, free-tier).
    public let rateLimit: RateLimit?

    /// Credit balance — typically `nil` for ChatGPT-subscription accounts;
    /// populated for API-credit accounts.
    public let credits: Credits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }

    /// The `rate_limit` object — **singular** (NOT the rollout's plural container).
    public struct RateLimit: Decodable, Sendable, Equatable {

        /// Short window (typical: 5-hour rolling).
        public let primaryWindow: Window?

        /// Long window (typical: 7-day rolling).
        public let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    /// One rate-limit window. **Schema diverges** from
    /// `CodexRolloutEvent.Window`: `reset_at` (no trailing `s`) + absolute Unix
    /// epoch seconds (no relative `resets_in_seconds` variant), and
    /// `limit_window_seconds` instead of `window_minutes`.
    public struct Window: Decodable, Sendable, Equatable {

        /// 0–100 percentage. Caller normalises to a 0.0–1.0 fraction for the UI.
        public let usedPercent: Int?

        /// Absolute Unix epoch **seconds** at which this window resets.
        public let resetAt: Int?

        /// Total length of the rolling window, in **seconds** (NOT minutes —
        /// this is the load-bearing correction).
        public let limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }

        /// Returns the absolute reset `Date` when `resetAt` is populated.
        public func resetDate() -> Date? {
            guard let epoch = resetAt else { return nil }
            return Date(timeIntervalSince1970: Double(epoch))
        }
    }

    /// Credit-balance summary. `balance` is `String` in live responses (matches
    /// `CodexRolloutEvent.Credits.balance` decision — observed values include
    /// `"0"`, `"100.50"`, and explicit JSON `null`).
    public struct Credits: Decodable, Sendable, Equatable {
        public let hasCredits: Bool?
        public let unlimited: Bool?
        public let balance: String?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited, balance
        }
    }
}

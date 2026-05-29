import Foundation

/// One line of a Codex rollout JSONL file (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).
///
/// Verified against live `~/.codex/sessions/` files spanning 2025-09 through
/// 2026-05 (see Phase 03-RESEARCH.md §"Codex Rollout JSONL Format"). Both
/// schemas decode through this single struct:
///
/// - **2026+ current:** `rate_limits.primary.resets_at` is an absolute Unix
///   timestamp in **seconds** (not milliseconds).
/// - **2025-09 legacy:** `rate_limits.primary.resets_in_seconds` is a relative
///   countdown. Some legacy files also ship `rate_limits: {}` (empty) — both
///   `primary` and `secondary` are then nil.
///
/// **CLAUDE-03 / Pitfall 7 — Lenient by default.** `JSONDecoder.decode(...)`
/// already silently ignores unknown JSON keys when the target struct does not
/// declare them. No `extraFields` / `AnyCodable` plumbing is required for
/// forward-compat — adding a hypothetical `payload.future_metric` to a
/// rollout line does NOT cause this decoder to throw, and existing fields
/// continue to populate normally. Phase 2 took the same stance for
/// `TranscriptRecord`.
public struct CodexRolloutEvent: Decodable, Sendable, Equatable {

    /// ISO8601 timestamp string. Parsed by callers (`CodexRolloutParser`) using
    /// the dual fractional / non-fractional pair (Phase 2 STATE #43 pattern).
    public let timestamp: String

    /// Top-level event type. `"event_msg"` is the only carrier of token counts;
    /// `"session_meta"`, `"response_item"`, `"turn_context"` are common other
    /// values that consumers MUST skip.
    public let type: String

    public let payload: Payload

    public struct Payload: Decodable, Sendable, Equatable {
        /// `"token_count"` for the events we care about. Other observed values
        /// include `"agent_message"`, `"task_started"`, etc. — all rejected by
        /// the parser's predicate.
        public let type: String

        /// Present on `token_count` events. May be `nil` on the very first
        /// event of a session (the model has not yet emitted any usage), and
        /// the parser treats `info == nil` as "not a usable event" per
        /// Pitfall 11 ("use the LAST token_count event with info != nil").
        public let info: TokenInfo?

        /// Present on `token_count` events. Legacy 2025-09 files may ship
        /// `rate_limits: {}` (everything nil); current files populate at least
        /// `primary` and `secondary`.
        public let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case type, info
            case rateLimits = "rate_limits"
        }
    }

    public struct TokenInfo: Decodable, Sendable, Equatable {
        /// Cumulative session totals — **use these for "session usage"**
        /// (Pitfall 11). The LAST `token_count` event's `total_token_usage`
        /// represents the session total because Codex emits monotonically
        /// increasing values across the session lifetime.
        public let totalTokenUsage: TokenUsage?

        /// Per-request delta — do NOT use for session totals. Present for
        /// completeness and possible future per-call surfacing.
        public let lastTokenUsage: TokenUsage?

        public let modelContextWindow: Int?

        enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage"
            case lastTokenUsage = "last_token_usage"
            case modelContextWindow = "model_context_window"
        }
    }

    public struct TokenUsage: Decodable, Sendable, Equatable {
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        /// Reasoning tokens — present on o1/o3-style models. Optional because
        /// older non-reasoning models omit the field entirely.
        public let reasoningOutputTokens: Int?
        public let totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
            case totalTokens = "total_tokens"
        }
    }

    public struct RateLimits: Decodable, Sendable, Equatable {
        public let limitId: String?
        public let limitName: String?
        public let primary: Window?
        public let secondary: Window?
        public let credits: Credits?
        /// Plan label — e.g. `"plus"`, `"pro"`, `"team"`, `"business"`,
        /// `"enterprise"`, `"edu"`, `"free"`, `"guest"`, `"null"` (legacy).
        public let planType: String?
        public let rateLimitReachedType: String?

        enum CodingKeys: String, CodingKey {
            case limitId = "limit_id"
            case limitName = "limit_name"
            case primary, secondary, credits
            case planType = "plan_type"
            case rateLimitReachedType = "rate_limit_reached_type"
        }
    }

    /// A single rate-limit window. Carries either `resets_at` (current 2026+
    /// format, absolute Unix epoch seconds) OR `resets_in_seconds` (legacy
    /// 2025-09 format, relative countdown). Exactly one is populated in
    /// well-formed files; `resetsAtDate(now:)` normalises to absolute `Date`.
    public struct Window: Decodable, Sendable, Equatable {
        public let usedPercent: Int
        public let windowMinutes: Int
        /// Current 2026+ format — absolute Unix epoch **seconds** (NOT
        /// milliseconds; verified from live files).
        public let resetsAt: Int?
        /// Legacy 2025-09 format — relative countdown in seconds.
        public let resetsInSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
            case resetsInSeconds = "resets_in_seconds"
        }

        /// Returns the absolute reset `Date` regardless of which schema variant
        /// is present. Returns `nil` only when both fields are absent (a
        /// genuinely under-populated rate-limit object — e.g. early sessions).
        public func resetsAtDate(now: Date = Date()) -> Date? {
            if let epoch = resetsAt {
                return Date(timeIntervalSince1970: Double(epoch))
            }
            if let seconds = resetsInSeconds {
                return now.addingTimeInterval(Double(seconds))
            }
            return nil
        }
    }

    public struct Credits: Decodable, Sendable, Equatable {
        public let hasCredits: Bool?
        public let unlimited: Bool?
        /// String-typed in live files: observed values include `"0"`, `"100.50"`,
        /// and explicit JSON `null`. Decoding as `String?` matches the live shape;
        /// the whole `credits` object is also often `null`.
        public let balance: String?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited, balance
        }
    }
}

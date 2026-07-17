import Foundation

/// Decodable subset of the JSON that Claude Code pushes to a statusline command on stdin.
///
/// The Agents Usage Bar "hook" integration installs a statusline *tee* script
/// (`aub-statusline.sh`) that captures this JSON into
/// `~/Library/Application Support/AgentsUsageBar/claude-hook/sessions/<session_id>.json`,
/// then chains to the user's original statusline. `ClaudeHookProvider` reads those
/// captured payloads back.
///
/// Verified fields (code.claude.com/docs/en/statusline, 2026-07-17):
/// - `session_id` (String) — resets on `/clear` (new session_id, cost restarts at 0).
/// - `transcript_path` (String) — the session's transcript JSONL location; encodes the
///   owning account (`~/.ccs/instances/<slug>/…` vs `~/.claude/…`).
/// - `model.id`, `model.display_name`.
/// - `cost.total_cost_usd` (Double) — cumulative, client-computed cost for THIS session.
/// - `rate_limits.five_hour|seven_day.used_percentage` (0–100 Double) — Pro/Max only,
///   appears after the first API response; each window independently absent; may be null early.
/// - `rate_limits.five_hour|seven_day.resets_at` (Unix epoch **SECONDS**, Double).
///
/// Every field is optional — API-key users have no `rate_limits`, and windows/percentages
/// can be absent or null in the early moments of a session. Decoding uses
/// `.convertFromSnakeCase` (see ``decode(_:)``), which maps `total_cost_usd` → `totalCostUsd`,
/// `used_percentage` → `usedPercentage`, `resets_at` → `resetsAt`, `five_hour` → `fiveHour`,
/// `seven_day` → `sevenDay`, `session_id` → `sessionId`, `display_name` → `displayName`.
public struct ClaudeHookPayload: Decodable, Sendable, Equatable {

    /// The Claude Code session this payload describes. `nil` if the field is absent.
    public let sessionId: String?

    /// Path to the session's transcript JSONL. This is the RELIABLE account signal:
    /// ccs instances store transcripts under `~/.ccs/instances/<slug>/projects/...`,
    /// whereas the tee script's `$CLAUDE_CONFIG_DIR`-based directory routing has been
    /// observed to flap across invocations for one session (a work-env fire can capture
    /// a personal session's payload). `ClaudeHookProvider` prefers this over the
    /// directory the file landed in.
    public let transcriptPath: String?

    /// The active model for this session.
    public let model: Model?

    /// Cumulative session cost reported by Claude Code.
    public let cost: Cost?

    /// Per-window rate-limit utilization + reset times. Absent for API-key users.
    public let rateLimits: RateLimits?

    /// The `model` object subset.
    public struct Model: Decodable, Sendable, Equatable {
        public let id: String?
        public let displayName: String?
    }

    /// The `cost` object subset.
    public struct Cost: Decodable, Sendable, Equatable {
        /// Cumulative session cost in USD (client-computed by Claude Code).
        public let totalCostUsd: Double?
    }

    /// The `rate_limits` object — one window per rolling period.
    public struct RateLimits: Decodable, Sendable, Equatable {
        /// The 5-hour rolling window (Pro/Max only).
        public let fiveHour: Window?
        /// The 7-day rolling window (Pro/Max only).
        public let sevenDay: Window?
    }

    /// A single rate-limit window.
    public struct Window: Decodable, Sendable, Equatable {
        /// Consumed fraction as a 0–100 percentage. `nil` when the API omits/nulls it early.
        public let usedPercentage: Double?

        /// Reset time as **Unix epoch seconds**. `nil` when absent.
        /// Convert to a `Date` via ``resetsAtDate``.
        public let resetsAt: Double?

        /// The reset time as a `Date`, or `nil` when `resetsAt` is absent.
        public var resetsAtDate: Date? {
            resetsAt.map { Date(timeIntervalSince1970: $0) }
        }
    }

    /// Decodes a payload from raw statusline JSON using the snake_case strategy
    /// shared by ``ClaudeHookProvider``. Keeps the decoder configuration in one place
    /// so tests and the provider agree on field mapping.
    public static func decode(_ data: Data) throws -> ClaudeHookPayload {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ClaudeHookPayload.self, from: data)
    }
}

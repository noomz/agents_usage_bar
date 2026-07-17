import Foundation

/// Selects which mechanism the Claude row uses to derive today's usage.
///
/// Stored as a `String` rawValue in `UserDefaults` under
/// `AUBDefaultsKey.claudeSource` and round-tripped via `init(rawValue:)`.
///
/// - `sessionReads`: reconstruct tokens/cost from `~/.claude/projects/**` JSONL
///   transcripts and poll the OAuth `usage` endpoint for quota (existing default
///   behavior — `ClaudeJSONLProvider`).
/// - `hook`: read real usage Claude Code pushes to its status line
///   (`cost.total_cost_usd` + `rate_limits.*.used_percentage`/`resets_at`),
///   captured by an installed statusline tee. No JSONL reads, no network.
///
/// Default is `.sessionReads` so existing behavior is preserved when the key
/// is absent (fail-soft on any unknown rawValue).
public enum ClaudeUsageSource: String, Sendable, Equatable, CaseIterable {
    case sessionReads   // JSONL transcripts + OAuth usage endpoint (existing)
    case hook           // statusline-tee feed (real Claude Code-reported usage + rate limits)
}

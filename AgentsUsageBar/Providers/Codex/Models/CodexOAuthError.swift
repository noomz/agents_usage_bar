import Foundation

/// Errors surfaced by `CodexCredentialLoader` (indirectly — the loader returns
/// `nil` rather than throwing) and `CodexOAuthClient` (directly — typed remap of
/// `HTTPError` from the wham/usage GET).
///
/// **Status disposition** (Phase 03 D-03):
/// - `noCredentials` — no `~/.codex/auth.json` present, or file present but
///   resolves neither a top-level `OPENAI_API_KEY` nor a `tokens.access_token`.
///   The Codex provider renders a muted "No data yet" row when BOTH the rollout
///   scan and this error coincide.
/// - `unauthorized(status:)` — 401 or 403 from `chatgpt.com/backend-api/wham/usage`.
///   Terminal until the user re-authenticates via the Codex CLI; we cannot refresh
///   the bearer ourselves (RESEARCH "No token refresh for Codex"). Provider maps
///   this to the same muted "No data yet" UX (D-03), NOT a red error row.
/// - `usageEndpointFailed(status:)` — 429 or any 5xx from the usage endpoint.
///   Feeds the AggregateStore-level `CircuitBreaker` (POLL-05 / STATE #56) — five
///   consecutive failures open the breaker for the standard 300s cooldown.
/// - `fileFormat(detail:)` — Reserved for the OAuth-client path; the loader itself
///   never throws this (it returns `nil` instead — loadCredentials is best-effort).
///   Kept on the enum so future composition can surface "auth.json present but
///   schema is alien" explicitly without inventing a new error.
public enum CodexOAuthError: Error, Sendable, Equatable {

    /// No usable credential could be resolved from `~/.codex/auth.json`.
    case noCredentials

    /// 401 / 403 from `wham/usage`. Terminal until user re-authenticates.
    case unauthorized(status: Int)

    /// 429 / 5xx from `wham/usage`. Feeds POLL-05 circuit breaker.
    case usageEndpointFailed(status: Int)

    /// Malformed `auth.json` (best-effort diagnostic — loader returns `nil` rather
    /// than throwing this; reserved for the OAuth client path if/when needed).
    case fileFormat(detail: String)
}

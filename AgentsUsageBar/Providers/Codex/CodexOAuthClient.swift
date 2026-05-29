import Foundation
import os.log

// MARK: - CodexOAuthClient

/// Performs the Codex **OAuth-usage fallback**: `GET
/// https://chatgpt.com/backend-api/wham/usage` using the bearer (and optional
/// `ChatGPT-Account-Id` header) from `~/.codex/auth.json`.
///
/// **Composition boundary (D-02):** This actor is invoked by `CodexJSONLProvider`
/// (Plan 03-04) **only when the local rollout scan yields zero `token_count`
/// events**. It is never called per-poll for users with active sessions; it
/// exists for cold boxes / brand-new users.
///
/// **No refresh path (RESEARCH "No token refresh for Codex"):** Unlike
/// `ClaudeOAuthClient`, this actor does NOT call a token-refresh endpoint. The
/// Codex CLI manages its own bearer rotation; when our cached bearer 401s we
/// degrade to the muted "No data yet" row (D-03) and wait for the user to
/// re-authenticate via `codex login` out-of-band. The `clock` parameter is
/// retained for parity with `ClaudeOAuthClient.init` and to leave a seam for
/// any future expiry-check logic without breaking call sites.
///
/// **SEC-01 invariant:** This file MUST NOT call the credential-reveal accessor.
/// The bearer is passed to `http.get` as a `Secret`; the single sanctioned reveal
/// site is `URLSessionHTTPClient.performGet` (Phase 1 STATE #15).
public actor CodexOAuthClient {

    /// Usage endpoint — RESEARCH §"Codex OAuth Fallback" verified.
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    // MARK: - Private

    private let http: any HTTPClient
    private let credentialLoader: CodexCredentialLoader
    private let clock: any Clock
    private let logger = AppLogger.logger(category: "codex-oauth")

    // MARK: - Init

    /// - Parameters:
    ///   - http: Shared URLSession-backed HTTP client (POLL-08 singleton invariant).
    ///   - credentialLoader: `~/.codex/auth.json` resolver (default: production loader).
    ///   - clock: Clock abstraction (parity-only seam — Codex has no refresh path).
    public init(
        http: any HTTPClient,
        credentialLoader: CodexCredentialLoader = CodexCredentialLoader(),
        clock: any Clock = SystemClock()
    ) {
        self.http = http
        self.credentialLoader = credentialLoader
        self.clock = clock
    }

    // MARK: - Public API

    /// Fetches today's quota utilization from `wham/usage`.
    ///
    /// Algorithm:
    /// 1. Resolve credentials via `CodexCredentialLoader` — throws
    ///    `CodexOAuthError.noCredentials` if `nil`.
    /// 2. Build headers: `Accept` + `User-Agent` always; include
    ///    `ChatGPT-Account-Id` only when `bearer.accountId != nil` (workspace/team
    ///    users — personal accounts omit it entirely).
    /// 3. GET the endpoint with the bearer as `Secret`.
    /// 4. Map `HTTPError`:
    ///    - 401 / 403 → `CodexOAuthError.unauthorized(status:)` — terminal until
    ///      user re-authenticates; provider renders muted "No data yet" (D-03).
    ///    - 429 / any non-2xx → `CodexOAuthError.usageEndpointFailed(status:)` —
    ///      feeds POLL-05 circuit breaker via AggregateStore.
    /// 5. `DecodingError` and other errors are rethrown unchanged.
    public func fetchUsage() async throws -> CodexUsageResponse {
        guard let creds = credentialLoader.loadCredentials() else {
            throw CodexOAuthError.noCredentials
        }

        var extraHeaders: [String: String] = [
            "Accept": "application/json",
            "User-Agent": "Agents-Usage-Bar/1.0",
        ]
        if let accountId = creds.bearer.accountId {
            extraHeaders["ChatGPT-Account-Id"] = accountId
        }

        do {
            // useSnakeCaseConversion: false — CodexUsageResponse declares explicit
            // snake_case CodingKey rawValues (matches RESEARCH correction #5 schema
            // for wham/usage). The .convertFromSnakeCase strategy would rewrite
            // incoming keys to camelCase before lookup, silently producing
            // `rateLimit == nil` despite a 200 OK body (G-02 root cause).
            return try await http.get(
                Self.endpoint,
                bearer: creds.bearer.token,
                extraHeaders: extraHeaders,
                useSnakeCaseConversion: false,
                as: CodexUsageResponse.self
            )
        } catch let httpErr as HTTPError {
            switch httpErr.status {
            case 401, 403:
                // SEC-02: log the resolved source label only — never the bearer.
                logger.notice("wham/usage \(httpErr.status, privacy: .public) — unauthorized (source=\(String(describing: creds.source), privacy: .public))")
                throw CodexOAuthError.unauthorized(status: httpErr.status)
            default:
                logger.notice("wham/usage \(httpErr.status, privacy: .public) — endpoint failed")
                throw CodexOAuthError.usageEndpointFailed(status: httpErr.status)
            }
        }
        // DecodingError + other errors propagate unchanged (AggregateStore
        // breaker treats them as generic failures per CLAUDE-04 precedent).
    }
}

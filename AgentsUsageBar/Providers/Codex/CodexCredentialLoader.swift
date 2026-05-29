import Foundation
import os.log

// MARK: - CodexCredentialLoader

/// Resolves Codex credentials from `~/.codex/auth.json` written by the Codex CLI.
///
/// **Bearer resolution priority** (RESEARCH §"Codex auth.json Schema", correction #4):
/// 1. Top-level `OPENAI_API_KEY` if it is a non-null, non-empty string — API-key users.
/// 2. Else `tokens.access_token` — subscription / ChatGPT-Plus users (JWT).
/// 3. If neither present — returns `nil` (no throw; downstream surfaces
///    `CodexOAuthError.noCredentials` only when the OAuth client actually needs it).
///
/// `tokens.account_id` is forwarded as an opaque workspace identifier; it identifies
/// the team/workspace, NOT a credential, so it is **never** wrapped in `Secret` —
/// it travels in cleartext via the `ChatGPT-Account-Id` HTTP header.
///
/// **Diverges from `ClaudeCredentialLoader`:** No Keychain path (Codex stores nothing
/// in Keychain) and no `needsRefresh` / `saveCredentials` (Codex has no refresh path —
/// the Codex CLI manages its own rotation; we degrade-to-local on 401 instead).
///
/// SEC-01: The bearer is wrapped in `Secret` immediately when constructing
/// `Bearer.token`. The struct must NEVER call the credential-reveal accessor —
/// only `URLSessionHTTPClient.performGet` is permitted that call site.
///
/// Source: Modelled on `ClaudeCredentialLoader`'s file-read flow plus the verified
/// `~/.codex/auth.json` shape (RESEARCH correction #4):
/// ```json
/// {
///   "last_refresh": "2026-05-13T11:47:21Z",
///   "OPENAI_API_KEY": null,
///   "tokens": {
///     "access_token": "eyJhbGci…",
///     "account_id": "d9295b13…",
///     "id_token": "eyJhbGci…",
///     "refresh_token": "rt_MQU-O…"
///   }
/// }
/// ```
public struct CodexCredentialLoader: Sendable {

    // MARK: - Nested types

    /// A resolved bearer token plus the optional `account_id` workspace identifier.
    ///
    /// SEC-01: `token` is `Secret`-wrapped at construction; the underlying string
    /// is reachable only via the `Secret` reveal accessor inside the HTTP layer.
    public struct Bearer: Sendable, Equatable {
        /// The bearer credential. `description` is always `"<redacted>"`.
        public let token: Secret
        /// Optional workspace identifier — forwarded as `ChatGPT-Account-Id`.
        /// Not a credential; `nil` for personal accounts.
        public let accountId: String?

        public init(token: Secret, accountId: String?) {
            self.token = token
            self.accountId = accountId
        }
    }

    /// Which auth.json field yielded the bearer.
    public enum Source: Sendable, Equatable {
        /// Top-level `OPENAI_API_KEY` — direct API-key users (no subscription).
        case apiKey
        /// `tokens.access_token` — ChatGPT subscription users (JWT bearer).
        case subscription
    }

    /// Bearer + resolution-source. Source is logged at `.notice` for diagnostics
    /// (SEC-02: the source label is `.public`; the token is never logged).
    public struct Result: Sendable, Equatable {
        public let bearer: Bearer
        public let source: Source

        public init(bearer: Bearer, source: Source) {
            self.bearer = bearer
            self.source = source
        }
    }

    // MARK: - Constants

    private static let defaultAuthRelPath = "/.codex/auth.json"

    // MARK: - Stored properties (all let — Sendable-safe)

    private let authPath: URL
    private let logger = AppLogger.logger(category: "codex-oauth")

    // MARK: - Init

    /// Designated initialiser — injectable for tests.
    ///
    /// - Parameters:
    ///   - authPath: Override for the auth.json URL. `nil` uses the default
    ///     `~/.codex/auth.json` resolved via `NSHomeDirectory()`.
    public init(authPath: URL? = nil) {
        self.authPath = authPath
            ?? URL(fileURLWithPath: NSHomeDirectory() + Self.defaultAuthRelPath)
    }

    // MARK: - Public API

    /// Resolves credentials per the priority chain documented on the type.
    ///
    /// Returns `nil` (never throws) when:
    /// - the file is absent,
    /// - the file is unreadable / malformed JSON,
    /// - or neither bearer-resolution path yields a non-empty string.
    public func loadCredentials() -> Result? {
        guard let data = try? Data(contentsOf: authPath) else {
            return nil
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        // Priority 1: top-level OPENAI_API_KEY (non-null, non-empty).
        // SEC-01: Secret-wrap at the absolute last moment.
        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            logger.notice("auth resolved via \(String(describing: Source.apiKey), privacy: .public)")
            return Result(
                bearer: Bearer(token: Secret(apiKey), accountId: nil),
                source: .apiKey
            )
        }

        // Priority 2: tokens.access_token (non-empty) → subscription path.
        if let tokens = json["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String,
           !access.isEmpty
        {
            let accountId = tokens["account_id"] as? String
            logger.notice("auth resolved via \(String(describing: Source.subscription), privacy: .public)")
            return Result(
                bearer: Bearer(token: Secret(access), accountId: accountId),
                source: .subscription
            )
        }

        // No usable credential.
        return nil
    }
}

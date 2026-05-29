import Foundation
import os.log

// MARK: - KeychainProtocol

/// Narrow seam for Keychain read/write operations.
///
/// Scoped tightly to the two operations `ClaudeCredentialLoader` needs,
/// so the test fake is trivially small.
///
/// `KeychainReader` conforms to this protocol in the production path.
/// Tests inject a `FakeKeychain` conformance.
public protocol KeychainProtocol: Sendable {
    func readGenericPassword(service: String, account: String?) throws -> Data
    func writeGenericPassword(_ data: Data, service: String, account: String?) throws
}

// MARK: - ClaudeCredentialLoader

/// Resolves Claude OAuth credentials from three sources in priority order:
/// 1. `~/.claude/.credentials.json` (file)
/// 2. Keychain item `"Claude Code-credentials"` (generic-password)
/// 3. `CLAUDE_CODE_OAUTH_TOKEN` environment variable
///
/// The first source that yields a non-nil `OAuth` with a non-empty `accessToken` wins.
///
/// Both JSON credential shapes are accepted (RESEARCH §A2, Assumption A2):
/// - `{ "claudeAiOauth": { ... } }` — current Claude Code naming
/// - `{ "mcpOAuth": { ... } }` — older MCP naming (found on some dev machines)
///
/// SEC-01: `accessToken` is kept as a raw `String` inside this loader.
/// The caller (`ClaudeOAuthClient`) wraps it in `Secret` immediately before use.
/// This struct must NEVER call `revealForRequest()`.
///
/// Source: Modelled on ClaudeBar/Sources/Infrastructure/Claude/ClaudeCredentialLoader.swift
/// (verified working production code; in use since 2025).
public struct ClaudeCredentialLoader: Sendable {

    // MARK: - Nested types

    /// A decoded set of Claude OAuth tokens.
    public struct OAuth: Sendable, Equatable {
        /// The raw bearer token. Wrapped in `Secret` by `ClaudeOAuthClient` before use.
        public var accessToken: String
        /// Refresh token used to obtain a new access token before expiry.
        public var refreshToken: String?
        /// Expiry timestamp in **milliseconds** since Unix epoch. Matches Anthropic schema.
        public var expiresAt: Double?
        /// E.g. `"claude_max"`, `"claude_pro"`. Not returned on refresh — preserve across rotations.
        public var subscriptionType: String?

        public init(
            accessToken: String,
            refreshToken: String?,
            expiresAt: Double?,
            subscriptionType: String?
        ) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.subscriptionType = subscriptionType
        }
    }

    /// Which source yielded the credential.
    public enum Source: Sendable, Equatable {
        case file
        case keychain
        case environment
    }

    /// The resolved credential paired with its origin source.
    public struct Result: Sendable, Equatable {
        public var oauth: OAuth
        public let source: Source

        public init(oauth: OAuth, source: Source) {
            self.oauth = oauth
            self.source = source
        }
    }

    // MARK: - Constants

    private static let keychainService = "Claude Code-credentials"
    private static let envKey = "CLAUDE_CODE_OAUTH_TOKEN"
    private static let defaultCredentialsRelPath = "/.claude/.credentials.json"

    // MARK: - Stored properties (all let — Sendable-safe)

    private let keychain: any KeychainProtocol
    private let env: [String: String]
    private let credentialsPath: URL?
    private let logger = AppLogger.logger(category: "oauth")

    // MARK: - Init

    /// Designated initialiser — injectable for tests.
    ///
    /// - Parameters:
    ///   - keychain: Keychain accessor (default: `KeychainReader()`).
    ///   - env: Process environment dictionary (default: `ProcessInfo.processInfo.environment`).
    ///   - credentialsPath: Override for the credentials file URL. `nil` uses the default
    ///     `~/.claude/.credentials.json`.
    public init(
        keychain: (any KeychainProtocol)? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment,
        credentialsPath: URL? = nil
    ) {
        // Swift 6 strict concurrency: existential default parameter values are not
        // statically verifiable, so KeychainReader() is instantiated here instead.
        self.keychain = keychain ?? KeychainReader()
        self.env = env
        self.credentialsPath = credentialsPath
    }

    // MARK: - Public API

    /// Resolves credentials using the file → Keychain → env priority chain.
    ///
    /// Returns `nil` if no source yields a valid credential (rather than throwing),
    /// so callers can surface a clean "no credentials" error.
    public func loadCredentials() -> Result? {
        if let r = loadFromFile()     { return r }
        if let r = loadFromKeychain() { return r }
        if let r = loadFromEnv()      { return r }
        return nil
    }

    /// Returns `true` when the access token should be refreshed before use.
    ///
    /// Refresh is needed when:
    /// - `expiresAt` is `nil` (unknown expiry → always refresh for safety), OR
    /// - The token expires within `refreshBufferMs` milliseconds of `now`.
    ///
    /// Default buffer is 5 minutes (300 000 ms).
    public func needsRefresh(
        _ o: OAuth,
        now: Date = .now,
        refreshBufferMs: Double = 5 * 60 * 1000
    ) -> Bool {
        guard let expiresAt = o.expiresAt else { return true }
        let nowMs = now.timeIntervalSince1970 * 1000
        return nowMs + refreshBufferMs >= expiresAt
    }

    /// Persists rotated tokens back to `source`.
    ///
    /// // SEC-NOTE: We write back rotated tokens to the same source we read them from.
    /// // This mutates state owned by Claude Code itself. The alternative — burning a
    /// // refresh round-trip on every poll — is worse for both us and Anthropic's servers.
    /// // Default decision #1 from CLAUDE.md root + RESEARCH Open Question 1:
    /// // mirroring ClaudeBar precedent (ClaudeBar writes rotated tokens to the same
    /// // credentials file on every successful refresh).
    /// //
    /// // Write-back is fire-and-forget (try? at the call site in ClaudeOAuthClient)
    /// // so a transient Keychain ACL error never blocks the usage fetch itself.
    public func saveCredentials(_ oauth: OAuth, to source: Source) throws {
        switch source {
        case .file:
            let url = credentialsPath ?? URL(
                fileURLWithPath: NSHomeDirectory() + Self.defaultCredentialsRelPath
            )
            let envelope = buildEnvelope(oauth)
            let data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted])
            try data.write(to: url, options: .atomic)
            logger.notice("oauth: wrote rotated credentials to file (SEC-NOTE write-back)")

        case .keychain:
            let envelope = buildEnvelope(oauth)
            let data = try JSONSerialization.data(withJSONObject: envelope, options: [])
            try keychain.writeGenericPassword(data, service: Self.keychainService, account: nil)
            logger.notice("oauth: wrote rotated credentials to Keychain (SEC-NOTE write-back)")

        case .environment:
            // SEC-NOTE: env-source tokens are set externally (shell rc / CI).
            // Writing back to env is not possible from within a process.
            // This is a no-op; the token will be used as-is until the next process launch.
            logger.notice("oauth: env-source credential — write-back is a no-op (expected for env-set tokens)")
        }
    }

    // MARK: - Private helpers

    private func loadFromFile() -> Result? {
        let url = credentialsPath ?? URL(
            fileURLWithPath: NSHomeDirectory() + Self.defaultCredentialsRelPath
        )
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeOAuthBlob(data, source: .file)
    }

    private func loadFromKeychain() -> Result? {
        do {
            let data = try keychain.readGenericPassword(
                service: Self.keychainService,
                account: nil
            )
            return decodeOAuthBlob(data, source: .keychain)
        } catch KeychainReaderError.itemNotFound {
            // Normal case — no Keychain entry exists yet.
            return nil
        } catch KeychainReaderError.authFailed {
            // Pitfall A11: swallow silently. Propagating this would trigger a Keychain
            // auth dialog cascade that blocks the UI. Fall through to env.
            logger.info("oauth: Keychain authFailed — degrading silently (Pitfall A11)")
            return nil
        } catch {
            // Unexpected Keychain error — log category+code only (SEC-02: never log data).
            logger.error("oauth: Keychain read failed with unexpected error — falling through")
            return nil
        }
    }

    private func loadFromEnv() -> Result? {
        guard let token = env[Self.envKey], !token.isEmpty else { return nil }
        // Env tokens are long-lived setup tokens (RESEARCH §B.3).
        // They carry no expiry or refresh token.
        return Result(
            oauth: OAuth(
                accessToken: token,
                refreshToken: nil,
                expiresAt: nil,
                subscriptionType: nil
            ),
            source: .environment
        )
    }

    /// Decodes the `claudeAiOauth` OR `mcpOAuth` JSON blob (RESEARCH §A2, §B.3).
    ///
    /// Tries `claudeAiOauth` first (current shape), falls back to `mcpOAuth` (legacy shape).
    /// Returns `nil` if neither key is present, or if `accessToken` is missing/empty.
    private func decodeOAuthBlob(_ data: Data, source: Source) -> Result? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let blob = (json["claudeAiOauth"] as? [String: Any])
            ?? (json["mcpOAuth"] as? [String: Any])
        guard let blob,
              let access = blob["accessToken"] as? String,
              !access.isEmpty
        else { return nil }

        return Result(
            oauth: OAuth(
                accessToken: access,
                refreshToken: blob["refreshToken"] as? String,
                expiresAt: blob["expiresAt"] as? Double,
                subscriptionType: blob["subscriptionType"] as? String
            ),
            source: source
        )
    }

    /// Builds the canonical `{"claudeAiOauth": {...}}` envelope for write-back.
    ///
    /// Always writes the `claudeAiOauth` shape (even if originally read from `mcpOAuth`)
    /// to normalise the format going forward — this is intentional and silent.
    private func buildEnvelope(_ oauth: OAuth) -> [String: Any] {
        var blob: [String: Any] = ["accessToken": oauth.accessToken]
        if let r = oauth.refreshToken     { blob["refreshToken"] = r }
        if let e = oauth.expiresAt        { blob["expiresAt"] = e }
        if let s = oauth.subscriptionType { blob["subscriptionType"] = s }
        return ["claudeAiOauth": blob]
    }
}

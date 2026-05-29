import Foundation
import os.log

// MARK: - GeminiCredentialLoader
//
// v1 reads ONLY `~/.gemini/oauth_creds.json`. No Keychain branch (gemini-cli
// HybridTokenStorage requires the `keychain-access-groups` entitlement which
// we do not ship; Pitfall 9).
//
// Pitfall 9 contract: when `oauth_creds.json` is absent but `settings.json`
// still says `oauth-personal`, this loader returns nil. The downstream
// provider (Plan 03-06) renders a muted "No data yet" row — never an error.
//
// SEC-02: logger interpolations carry only the resolution category. Never
// log `access_token`, `refresh_token`, `expiry_date`, `scope`, `id_token`.
//
// SEC-01: this struct must NEVER call the credential-reveal accessor. The
// `Secret` wrap happens inside `GeminiOAuthClient` at URLRequest construction
// — Phase 1 STATE #15 invariant carried forward.

/// Loads the gemini-cli OAuth credentials from disk.
///
/// Returns `nil` for missing file, malformed JSON, or missing
/// `refresh_token` (file is unusable without it).
public struct GeminiCredentialLoader: Sendable {

    // MARK: - Nested types

    /// Resolution source — v1 has only the file path.
    public enum Source: Sendable, Equatable {
        case file
    }

    /// Pairs the decoded credentials with their resolution source.
    public struct Result: Sendable, Equatable {
        public let credentials: GeminiOAuthCredentials
        public let source: Source

        public init(credentials: GeminiOAuthCredentials, source: Source) {
            self.credentials = credentials
            self.source = source
        }
    }

    // MARK: - Constants

    private static let defaultCredentialsRelPath = "/.gemini/oauth_creds.json"

    // MARK: - Stored properties (all let — Sendable-safe)

    private let credentialsPath: URL
    private let logger = AppLogger.logger(category: "gemini-creds")

    // MARK: - Init

    /// - Parameters:
    ///   - credentialsPath: Override for the oauth_creds.json URL. `nil`
    ///     uses the default `~/.gemini/oauth_creds.json` via `NSHomeDirectory()`.
    ///   - fileManager: Reserved for symmetry — file reads use
    ///     `Data(contentsOf:)` which doesn't need a FileManager instance.
    public init(
        credentialsPath: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.credentialsPath = credentialsPath
            ?? URL(fileURLWithPath: NSHomeDirectory() + Self.defaultCredentialsRelPath)
    }

    // MARK: - Public API

    /// Resolves credentials from disk.
    ///
    /// Returns `nil` (never throws) for any failure mode:
    /// - file absent (Pitfall 9 — keychain migration; downstream muted row)
    /// - file unreadable / malformed JSON
    /// - file missing `refresh_token` (struct is unusable)
    public func loadCredentials() -> Result? {
        guard let data = try? Data(contentsOf: credentialsPath) else {
            logger.notice("credentials not found (Pitfall 9 keychain migration?)")
            return nil
        }
        guard
            let credentials = try? JSONDecoder().decode(GeminiOAuthCredentials.self, from: data)
        else {
            return nil
        }
        logger.notice("credentials resolved from \(String(describing: Source.file), privacy: .public)")
        return Result(credentials: credentials, source: .file)
    }
}

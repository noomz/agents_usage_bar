import Foundation
import os

/// Resolves a Grok billing bearer from `XAI_API_KEY` or `~/.grok/auth.json`.
///
/// Priority (matches the Grok CLI):
/// 1. First `auth.json` session `key` (grok login / SuperGrok).
/// 2. Non-empty `XAI_API_KEY` (env-only; never TOML) as fallback.
///    Wire shape is issuer-keyed: `{ "<issuer>::<client>": { "key": "...", ... } }`.
///    Older curl docs used `https://accounts.x.ai/sign-in` — both shapes work
///    because we iterate values rather than a hard-coded key.
///
/// No refresh path in v1 (Codex precedent). Stale tokens surface as HTTP 401
/// and the provider degrades until the user runs `grok login`.
///
/// SEC-01: the bearer is wrapped in `Secret` at construction. This type never
/// calls the reveal accessor.
public struct GrokCredentialLoader: Sendable {

    public enum Source: Sendable, Equatable {
        case apiKey
        case session
    }

    public struct Result: Sendable, Equatable {
        public let token: Secret
        public let source: Source

        public init(token: Secret, source: Source) {
            self.token = token
            self.source = source
        }
    }

    private let authPath: URL
    private let environment: [String: String]
    private let logger = AppLogger.logger(category: "grok")

    public init(
        authPath: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        let home = GrokRoots.home(fileManager: fileManager, environment: environment)
        self.authPath = authPath ?? GrokRoots.authJSON(home: home)
        self.environment = environment
    }

    public func loadCredentials() -> Result? {
        if let data = try? Data(contentsOf: authPath),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = firstSessionKey(in: root) {
            logger.notice("grok credentials: source=session")
            return Result(token: Secret(key), source: .session)
        }

        if let envKey = environment["XAI_API_KEY"], !envKey.isEmpty {
            logger.notice("grok credentials: source=apiKey")
            return Result(token: Secret(envKey), source: .apiKey)
        }
        return nil
    }

    /// Walks issuer-keyed objects and returns the first non-empty `key`.
    private func firstSessionKey(in root: [String: Any]) -> String? {
        for value in root.values {
            guard let entry = value as? [String: Any] else { continue }
            if let key = entry["key"] as? String, !key.isEmpty {
                return key
            }
        }
        return nil
    }
}

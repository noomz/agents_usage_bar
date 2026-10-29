import Foundation
import os

/// Resolves Grok billing bearers from Grok CLI session, Pi xAI OAuth, or env.
///
/// `loadCandidates()` order:
/// 1. First `~/.grok/auth.json` session `key` (grok login).
/// 2. Pi `auth.json` `xai.access` when `type` is `oauth` and not expired.
/// 3. Non-empty `XAI_API_KEY`.
/// The billing client tries each on 401. Grok CLI sessions often 401 while
/// Pi's xAI OAuth still works for unify weekly premium (`?format=credits`).
///
/// No refresh path in v1 (Codex precedent). Expired Pi `access` is skipped.
///
/// SEC-01: the bearer is wrapped in `Secret` at construction. This type never
/// calls the reveal accessor.
public struct GrokCredentialLoader: Sendable {

    public enum Source: Sendable, Equatable {
        case apiKey
        case session
        case piOAuth
    }

    public struct Result: Sendable, Equatable {
        public let token: Secret
        public let source: Source

        public init(token: Secret, source: Source) {
            self.token = token
            self.source = source
        }

        /// Grok CLI sessions need CLI headers. Pi OAuth and API keys do not.
        public var usesGrokCLIHeaders: Bool { source == .session }
    }

    private let authPath: URL
    private let piAuthPath: URL
    private let environment: [String: String]
    private let now: Date
    private let logger = AppLogger.logger(category: "grok")

    public init(
        authPath: URL? = nil,
        piAuthPath: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) {
        let home = GrokRoots.home(fileManager: fileManager, environment: environment)
        self.authPath = authPath ?? GrokRoots.authJSON(home: home)
        self.piAuthPath = piAuthPath ?? PiSessionRoots.agentDirectory(
            environment: environment,
            home: fileManager.homeDirectoryForCurrentUser.path
        ).appendingPathComponent("auth.json")
        self.environment = environment
        self.now = now
    }

    public func loadCredentials() -> Result? {
        loadCandidates().first
    }

    /// Ordered unique bearers for the billing client to try.
    public func loadCandidates() -> [Result] {
        var out: [Result] = []
        var seen: Set<Secret> = []
        func append(_ result: Result) {
            guard seen.insert(result.token).inserted else { return }
            out.append(result)
        }

        if let data = try? Data(contentsOf: authPath),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = firstSessionKey(in: root) {
            logger.notice("grok credentials: source=session")
            append(Result(token: Secret(key), source: .session))
        }

        if let access = piOAuthAccess() {
            logger.notice("grok credentials: source=piOAuth")
            append(Result(token: Secret(access), source: .piOAuth))
        }

        if let envKey = environment["XAI_API_KEY"], !envKey.isEmpty {
            logger.notice("grok credentials: source=apiKey")
            append(Result(token: Secret(envKey), source: .apiKey))
        }
        return out
    }

    private func piOAuthAccess() -> String? {
        guard
            let data = try? Data(contentsOf: piAuthPath),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let xai = root["xai"] as? [String: Any],
            (xai["type"] as? String) == "oauth",
            let access = xai["access"] as? String,
            !access.isEmpty
        else {
            return nil
        }
        if let expires = expiresDate(xai["expires"]), expires <= now {
            logger.notice("grok credentials: piOAuth expired")
            return nil
        }
        return access
    }

    /// Pi stores unix seconds or milliseconds.
    private func expiresDate(_ raw: Any?) -> Date? {
        let value: Double
        if let i = raw as? Int {
            value = Double(i)
        } else if let d = raw as? Double {
            value = d
        } else {
            return nil
        }
        let seconds = value > 1_000_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
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

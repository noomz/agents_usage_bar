import Foundation

/// One enabled ChatGPT subscription login found on disk.
///
/// CLIProxy files under `~/.ccs/cliproxy/auth/` and, when it is not a duplicate,
/// `~/.codex/auth.json`. The bearer stays inside `Secret`. Nothing here logs it.
struct CodexDiscoveredLogin: Sendable, Equatable, CustomStringConvertible {
    enum Source: Sendable, Equatable {
        case cliproxy(filename: String)
        case authJSON
    }

    let accountId: String?
    let accessToken: Secret
    /// CLIProxy `email` field. Nil when missing, empty, or the login is `auth.json`.
    let email: String?
    /// Lowercased last `-` segment of a CLIProxy filename. Nil for `auth.json`.
    let planSuffix: String?
    let source: Source

    var description: String {
        "CodexDiscoveredLogin(accountId: \(accountId ?? "nil"), token: \(accessToken), source: \(source))"
    }
}

/// Finds Codex subscription logins and assigns each a unique display label.
enum CodexLoginDiscovery {
    static let planSlugs: Set<String> = [
        "plus", "pro", "team", "business", "enterprise", "edu", "free", "guest",
    ]

    /// Reads `codex-*.json` in `directory`, then the optional Codex CLI auth file.
    ///
    /// A missing directory yields zero CLIProxy logins and does not throw.
    /// Paths are injectable so tests never touch the real home directory.
    static func discover(directory: URL, authPath: URL) -> [CodexDiscoveredLogin] {
        var logins: [CodexDiscoveredLogin] = []
        var seenAccountIDs = Set<String>()

        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names.filter(isCLIProxyFilename).sorted(by: <) {
                guard let login = parseCLIProxy(
                    url: directory.appendingPathComponent(name),
                    filename: name
                ), let accountId = login.accountId, !seenAccountIDs.contains(accountId) else {
                    continue
                }
                seenAccountIDs.insert(accountId)
                logins.append(login)
            }
        }

        appendAuthJSON(authPath: authPath, to: &logins, seenAccountIDs: seenAccountIDs)
        return logins
    }

    /// Unique labels for `logins`, sorted with `<`.
    ///
    /// `planTypes` maps `account_id` to the `wham/usage` `plan_type`. The login
    /// with no `account_id` reads `planTypes[""]`. Labels are assigned only when
    /// two or more logins are shown; callers with one login ignore the result.
    static func labeled(
        _ logins: [CodexDiscoveredLogin],
        planTypes: [String: String] = [:]
    ) -> [(login: CodexDiscoveredLogin, label: String)] {
        let options = logins.map { candidates(for: $0, among: logins, planTypes: planTypes) }
        var index = Array(repeating: 0, count: logins.count)
        let limit = (options.map(\.count).max() ?? 0) + 1
        for _ in 0..<limit {
            var buckets: [String: [Int]] = [:]
            for i in logins.indices {
                buckets[label(options[i], index: index[i]), default: []].append(i)
            }
            let shared = buckets.values.filter { $0.count > 1 }
            if shared.isEmpty { break }
            var moved = false
            for idxs in shared {
                for i in idxs where index[i] + 1 < options[i].count {
                    index[i] += 1
                    moved = true
                }
            }
            if !moved { break }
        }
        return logins.indices.map { i in
            (login: logins[i], label: label(options[i], index: index[i]))
        }.sorted { $0.label < $1.label }
    }

    // MARK: - Parsing

    private static func isCLIProxyFilename(_ name: String) -> Bool {
        name.hasPrefix("codex-") && name.hasSuffix(".json")
    }

    private static func parseCLIProxy(url: URL, filename: String) -> CodexDiscoveredLogin? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if json["disabled"] as? Bool == true { return nil }
        if let type = json["type"] as? String, type != "codex" { return nil }
        if json["type"] != nil, json["type"] is String == false { return nil }
        guard let token = nonEmpty(json["access_token"] as? String),
              let accountId = nonEmpty(json["account_id"] as? String)
        else { return nil }
        return CodexDiscoveredLogin(
            accountId: accountId,
            accessToken: Secret(token),
            email: nonEmpty(json["email"] as? String),
            planSuffix: filenamePlanSuffix(filename),
            source: .cliproxy(filename: filename)
        )
    }

    /// Last `-` segment of the filename stem, lowercased. Emails in the stem
    /// stay in earlier segments; the plan slug is the final one.
    static func filenamePlanSuffix(_ filename: String) -> String? {
        var stem = filename
        if stem.hasSuffix(".json") {
            stem.removeLast(".json".count)
        }
        guard let last = stem.split(separator: "-").last else { return nil }
        return String(last).lowercased()
    }

    private static func appendAuthJSON(
        authPath: URL,
        to logins: inout [CodexDiscoveredLogin],
        seenAccountIDs: Set<String>
    ) {
        guard let loaded = CodexCredentialLoader(authPath: authPath).loadCredentials(),
              loaded.source == .subscription
        else { return }
        if let accountId = nonEmpty(loaded.bearer.accountId) {
            guard !seenAccountIDs.contains(accountId) else { return }
            logins.append(CodexDiscoveredLogin(
                accountId: accountId,
                accessToken: loaded.bearer.token,
                email: nil,
                planSuffix: nil,
                source: .authJSON
            ))
            return
        }
        // No account id is a login only when nothing else was found. The call
        // omits ChatGPT-Account-Id, matching CodexOAuthClient.
        guard logins.isEmpty else { return }
        logins.append(CodexDiscoveredLogin(
            accountId: nil,
            accessToken: loaded.bearer.token,
            email: nil,
            planSuffix: nil,
            source: .authJSON
        ))
    }

    // MARK: - Labels

    private static func candidates(
        for login: CodexDiscoveredLogin,
        among logins: [CodexDiscoveredLogin],
        planTypes: [String: String]
    ) -> [String] {
        var options: [String] = []
        switch login.source {
        case .cliproxy:
            if let slug = login.planSuffix, planSlugs.contains(slug),
               logins.filter({ $0.planSuffix == slug && isCLIProxy($0) }).count == 1 {
                options.append(slug)
            }
            if let email = nonEmpty(login.email),
               logins.filter({ $0.email == email }).count == 1 {
                options.append(email)
            }
        case .authJSON:
            if let plan = authPlanType(login, planTypes: planTypes),
               planTypeIsUnique(plan, among: logins, planTypes: planTypes) {
                options.append(plan)
            }
        }
        if let accountId = nonEmpty(login.accountId) {
            options.append("acct-" + String(accountId.prefix(8)))
            if accountId.count > 8 {
                options.append("acct-" + accountId)
            }
        }
        return options
    }

    private static func authPlanType(
        _ login: CodexDiscoveredLogin,
        planTypes: [String: String]
    ) -> String? {
        nonEmpty(planTypes[login.accountId ?? ""])?.lowercased()
    }

    /// True when no other login already claims `plan` via its filename slug
    /// or its own `plan_type`.
    private static func planTypeIsUnique(
        _ plan: String,
        among logins: [CodexDiscoveredLogin],
        planTypes: [String: String]
    ) -> Bool {
        let claimers = logins.reduce(into: 0) { count, other in
            if other.planSuffix == plan {
                count += 1
                return
            }
            if case .authJSON = other.source, authPlanType(other, planTypes: planTypes) == plan {
                count += 1
            }
        }
        return claimers == 1
    }

    private static func isCLIProxy(_ login: CodexDiscoveredLogin) -> Bool {
        if case .cliproxy = login.source { return true }
        return false
    }

    private static func label(_ options: [String], index: Int) -> String {
        if options.indices.contains(index) { return options[index] }
        return options.last ?? "codex"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

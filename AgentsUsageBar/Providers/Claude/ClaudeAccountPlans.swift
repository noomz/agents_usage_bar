import Foundation

/// Billing model and plan of each Claude account, read from the account root's `.claude.json`
/// (SPEC I6, V25): `~/.claude.json` for `default`, `~/.ccs/instances/<slug>/.claude.json` for a
/// ccs instance. An `oauthAccount.organizationType` of `claude_<plan>` is a subscription; no
/// `oauthAccount` is an API key, so metered. No Keychain read.
///
/// The file holds Claude Code's whole state (hundreds of KB), so it is decoded again only when
/// its modification date changes.
struct ClaudeAccountPlans {
    private let home: URL
    private var cache: [String: (modified: Date, info: AccountInfo)] = [:]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    mutating func info(for account: String) -> AccountInfo {
        let url = Self.claudeJSON(for: account, home: home)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified else { return AccountInfo(billingModel: .metered) }
        if let cached = cache[account], cached.modified == modified {
            return cached.info
        }
        let info = (try? Data(contentsOf: url)).map(Self.info(fromClaudeJSON:)) ?? AccountInfo(billingModel: .metered)
        cache[account] = (modified, info)
        return info
    }

    static func claudeJSON(for account: String, home: URL) -> URL {
        guard account != "default" else {
            return home.appending(path: ".claude.json")
        }
        return home.appending(path: ".ccs/instances/\(account)/.claude.json")
    }

    static func info(fromClaudeJSON data: Data) -> AccountInfo {
        struct File: Decodable {
            struct OAuthAccount: Decodable {
                let organizationType: String?
            }
            let oauthAccount: OAuthAccount?
        }
        let prefix = "claude_"
        guard let type = (try? JSONDecoder().decode(File.self, from: data))?.oauthAccount?.organizationType,
              type.hasPrefix(prefix), type.count > prefix.count
        else { return AccountInfo(billingModel: .metered) }
        return AccountInfo(billingModel: .subscription, plan: String(type.dropFirst(prefix.count)))
    }
}

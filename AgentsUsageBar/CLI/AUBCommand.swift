import Foundation

/// Parsed `aub` invocation. Pure value — no I/O.
public enum AUBCommand: Equatable, Sendable {
    case usage(UsageOptions)
    case quota(UsageOptions)
    case settings(SettingsAction, json: Bool)
    case install(prefix: String?)
    case uninstall
    case version
    case help

    public struct UsageOptions: Equatable, Sendable {
        public var filter: ProviderFilter
        public var json: Bool
        public var noColor: Bool
        public var cached: Bool

        public init(
            filter: ProviderFilter = .enabled,
            json: Bool = false,
            noColor: Bool = false,
            cached: Bool = false
        ) {
            self.filter = filter
            self.json = json
            self.noColor = noColor
            self.cached = cached
        }
    }

    public enum ProviderFilter: Equatable, Sendable {
        case enabled
        case all
        case one(ProviderID)
    }

    public enum SettingsAction: Equatable, Sendable {
        case list
        case get(String)
        case set(key: String, value: String)
    }

    /// Tokens that force the GUI binary down the CLI path (see `AUBMain`).
    public static func isSubcommand(_ token: String) -> Bool {
        if token.hasPrefix("-psn") { return false }
        if Self.knownTokens.contains(token) { return true }
        if ProviderID.allKnown.contains(where: { $0.rawValue == token }) { return true }
        return false
    }

    private static let knownTokens: Set<String> = [
        "usage", "quota", "limits", "settings", "install", "uninstall",
        "version", "help",
        "--help", "-h", "--version", "-V",
        "--json", "--cached", "--no-color", "--provider", "--prefix", "--cli",
    ]

    public static let helpText = """
    aub — Agents Usage Bar command line

    Usage:
      aub [usage] [provider]   Print today's usage with quota bars
      aub quota [provider]     Print quota / limits / reset windows
      aub limits [provider]    Alias of quota
      aub settings             List settings keys and values
      aub settings get <key>
      aub settings set <key> <value>
      aub install [--prefix PATH]   Default: ~/.local/bin
      aub uninstall
      aub version
      aub help

    Flags:
      --json          Machine-readable JSON
      --no-color      Disable ANSI bar colors
      --cached        Read the menu-bar cache (no live fetch)
      --provider ID   Restrict to one provider, or 'all'
      --prefix PATH   Install symlink into PATH (install only)

    Providers:
      openrouter, claude, codex, gemini, grok, ollama, lmstudio, llamacpp

    Settings keys:
      refresh-interval, threshold, theme, pace-warnings,
      claude-source, open-at-login, provider.<id>.enabled

    Examples:
      aub
      aub usage --json
      aub quota claude
      aub settings get refresh-interval
      aub settings set threshold 0.7
    """
}

public enum AUBParseError: Error, Equatable, CustomStringConvertible, Sendable {
    case unknownCommand(String)
    case unknownProvider(String)
    case missingValue(String)
    case unexpectedArgument(String)
    case missingSettingsKey
    case missingSettingsValue

    public var description: String {
        switch self {
        case .unknownCommand(let s):
            return "unknown command '\(s)'. Try `aub help`."
        case .unknownProvider(let s):
            return "unknown provider '\(s)'. Try `aub help`."
        case .missingValue(let flag):
            return "missing value for \(flag)"
        case .unexpectedArgument(let s):
            return "unexpected argument '\(s)'. Try `aub help`."
        case .missingSettingsKey:
            return "missing settings key. Try `aub settings`."
        case .missingSettingsValue:
            return "missing settings value. Usage: aub settings set <key> <value>"
        }
    }
}

extension AUBCommand {

    public static func parse(_ args: [String]) -> Result<AUBCommand, AUBParseError> {
        var json = false
        var noColor = false
        var cached = false
        var providerFlag: String?
        var prefix: String?
        var positionals: [String] = []

        var i = 0
        let tokens = args.filter { $0 != "--cli" }
        while i < tokens.count {
            let t = tokens[i]
            switch t {
            case "--help", "-h":
                return .success(.help)
            case "--version", "-V":
                return .success(.version)
            case "--json":
                json = true
            case "--no-color":
                noColor = true
            case "--cached":
                cached = true
            case "--provider":
                i += 1
                guard i < tokens.count else { return .failure(.missingValue("--provider")) }
                providerFlag = tokens[i]
            case "--prefix":
                i += 1
                guard i < tokens.count else { return .failure(.missingValue("--prefix")) }
                prefix = tokens[i]
            default:
                if t.hasPrefix("-") {
                    return .failure(.unknownCommand(t))
                }
                positionals.append(t)
            }
            i += 1
        }

        let head = positionals.first
        let rest = Array(positionals.dropFirst())

        func usageOptions(defaultFilter: ProviderFilter = .enabled) -> Result<UsageOptions, AUBParseError> {
            switch makeFilter(flag: providerFlag, positional: rest.first, defaultFilter: defaultFilter) {
            case .failure(let e): return .failure(e)
            case .success(let filter):
                if rest.count > 1 {
                    return .failure(.unexpectedArgument(rest[1]))
                }
                return .success(UsageOptions(filter: filter, json: json, noColor: noColor, cached: cached))
            }
        }

        switch head {
        case nil:
            if let providerFlag {
                switch parseProviderToken(providerFlag) {
                case .failure(let e): return .failure(e)
                case .success(let filter):
                    return .success(.usage(UsageOptions(
                        filter: filter, json: json, noColor: noColor, cached: cached
                    )))
                }
            }
            return .success(.usage(UsageOptions(
                filter: .enabled, json: json, noColor: noColor, cached: cached
            )))
        case "help":
            return .success(.help)
        case "version":
            return .success(.version)
        case "usage":
            return usageOptions().map { .usage($0) }
        case "quota", "limits":
            return usageOptions().map { .quota($0) }
        case "settings":
            return parseSettings(rest, json: json)
        case "install":
            if let extra = rest.first { return .failure(.unexpectedArgument(extra)) }
            return .success(.install(prefix: prefix))
        case "uninstall":
            if let extra = rest.first { return .failure(.unexpectedArgument(extra)) }
            return .success(.uninstall)
        default:
            if let id = parseKnownProvider(head!) {
                if let extra = rest.first { return .failure(.unexpectedArgument(extra)) }
                return .success(.usage(UsageOptions(
                    filter: .one(id), json: json, noColor: noColor, cached: cached
                )))
            }
            return .failure(.unknownCommand(head!))
        }
    }

    private static func parseSettings(_ rest: [String], json: Bool) -> Result<AUBCommand, AUBParseError> {
        if rest.isEmpty { return .success(.settings(.list, json: json)) }
        switch rest[0] {
        case "get":
            guard rest.count >= 2 else { return .failure(.missingSettingsKey) }
            if rest.count > 2 { return .failure(.unexpectedArgument(rest[2])) }
            return .success(.settings(.get(rest[1]), json: json))
        case "set":
            guard rest.count >= 2 else { return .failure(.missingSettingsKey) }
            guard rest.count >= 3 else { return .failure(.missingSettingsValue) }
            if rest.count > 3 { return .failure(.unexpectedArgument(rest[3])) }
            return .success(.settings(.set(key: rest[1], value: rest[2]), json: json))
        default:
            return .failure(.unknownCommand("settings \(rest[0])"))
        }
    }

    private static func makeFilter(
        flag: String?,
        positional: String?,
        defaultFilter: ProviderFilter
    ) -> Result<ProviderFilter, AUBParseError> {
        if let flag {
            return parseProviderToken(flag)
        }
        if let positional {
            return parseProviderToken(positional)
        }
        return .success(defaultFilter)
    }

    private static func parseProviderToken(_ token: String) -> Result<ProviderFilter, AUBParseError> {
        if token == "all" { return .success(.all) }
        if let id = parseKnownProvider(token) { return .success(.one(id)) }
        return .failure(.unknownProvider(token))
    }

    private static func parseKnownProvider(_ token: String) -> ProviderID? {
        ProviderID.allKnown.first { $0.rawValue == token }
    }
}

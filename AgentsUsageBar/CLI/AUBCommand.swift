import Foundation

/// Parsed `aub` invocation. Pure value — no I/O.
public enum AUBCommand: Equatable, Sendable {
    case usage(UsageOptions)
    case quota(UsageOptions)
    case stats(StatsOptions)
    case settings(SettingsAction, json: Bool)
    case themes(json: Bool, theme: CLITheme?)
    case install(prefix: String?)
    case uninstall
    case version
    case help

    public struct UsageOptions: Equatable, Sendable {
        public var filter: ProviderFilter
        public var json: Bool
        public var noColor: Bool
        public var cached: Bool
        /// `--theme` value, validated at parse; nil = fall through to env/setting.
        public var theme: CLITheme?

        public init(
            filter: ProviderFilter = .enabled,
            json: Bool = false,
            noColor: Bool = false,
            cached: Bool = true,
            theme: CLITheme? = nil
        ) {
            self.filter = filter
            self.json = json
            self.noColor = noColor
            self.cached = cached
            self.theme = theme
        }
    }

    /// `aub stats` (SPEC V42–V46). The range resolves against today at run time.
    public struct StatsOptions: Equatable, Sendable {
        /// `.enabled` is the summary without local runtimes, `.all` adds them, `.one`
        /// drills down into one provider.
        public var filter: ProviderFilter
        public var days: Int?
        public var since: String?
        public var until: String?
        public var noColor: Bool
        public var format: StatsFormat

        public init(
            filter: ProviderFilter = .enabled,
            days: Int? = nil,
            since: String? = nil,
            until: String? = nil,
            noColor: Bool = false,
            format: StatsFormat = .text
        ) {
            self.filter = filter
            self.days = days
            self.since = since
            self.until = until
            self.noColor = noColor
            self.format = format
        }
    }

    /// `aub stats` output: the text table, or an export (V47).
    public enum StatsFormat: Equatable, Sendable {
        case text
        case json
        case csv(HistoryExportRenderer.CSVTable)
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
        "usage", "quota", "limits", "stats", "settings", "themes", "install", "uninstall",
        "version", "help",
        "--help", "-h", "--version", "-V",
        "--json", "--cached", "--live", "--no-color", "--provider", "--prefix", "--theme", "--cli",
        "--days", "--since", "--until", "--csv",
    ]

    public static let helpText = """
    aub — Agents Usage Bar command line

    Usage:
      aub [usage] [provider]   Print today's usage with quota bars
      aub quota [provider]     Print quota / limits / reset windows
      aub limits [provider]    Alias of quota
      aub stats [provider]     Usage history: 14-day summary, or one row per day
      aub stats --json | --csv [accounts|events|quota]   Export history (every retained day)
      aub settings             List settings keys and values
      aub settings get <key>
      aub settings set <key> <value>
      aub themes               List CLI themes and the active one
      aub install [--prefix PATH]   Default: ~/.local/bin
      aub uninstall
      aub version
      aub help

    Flags:
      --json          Machine-readable JSON
      --no-color      Disable ANSI bar colors
      --cached        Read the menu-bar cache (default; no live fetch)
      --live          Fetch providers now (slow; ignores the cache)
      --provider ID   Restrict to one provider, or 'all'
      --theme NAME    CLI theme: compact (default) | classic
      --prefix PATH   Install symlink into PATH (install only)
      --days N        Stats range length, ending today (default 14)
      --since DATE    Stats range start, yyyy-MM-dd
      --until DATE    Stats range end, yyyy-MM-dd
      --csv [TABLE]   Stats export as CSV: days (default), accounts, events, quota

    Environment:
      AUB_THEME       CLI theme when --theme is absent (overrides the cli-theme setting)
      NO_COLOR        Disable ANSI colors, like --no-color

    Providers:
      openrouter, claude, codex, gemini, grok, ollama, lmstudio, lms-llamacpp, llamacpp

    Settings keys:
      refresh-interval, threshold, theme, cli-theme, provider-order,
      pace-warnings, reset-notifications, claude-source, open-at-login,
      provider.<id>.enabled

    Examples:
      aub
      aub --live
      aub usage --json
      aub quota claude
      aub stats --days 30
      aub stats claude --since 2026-10-01
      aub stats --csv quota --days 30
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
    case unknownTheme(String)
    case unknownThemeEnv(String)
    case invalidDays(String)
    case invalidDay(flag: String, value: String)
    case emptyRange(String, String)

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
        case .unknownTheme(let s):
            return "unknown CLI theme '\(s)'; expected \(CLITheme.expectedNames)"
        case .unknownThemeEnv(let s):
            return "AUB_THEME: " + AUBParseError.unknownTheme(s).description
        case .invalidDays(let s):
            return "--days expects a whole number of days from 1, got '\(s)'"
        case .invalidDay(let flag, let value):
            return "\(flag) expects a date as yyyy-MM-dd, got '\(value)'"
        case .emptyRange(let first, let last):
            return "empty range: \(first) is after \(last)"
        }
    }
}

extension AUBCommand {

    public static func parse(_ args: [String]) -> Result<AUBCommand, AUBParseError> {
        var json = false
        var noColor = false
        var cached = true
        var providerFlag: String?
        var prefix: String?
        var theme: CLITheme?
        var days: Int?
        var since: String?
        var until: String?
        var rangeFlag: String?
        var csv: HistoryExportRenderer.CSVTable?
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
            case "--live":
                cached = false
            case "--provider":
                i += 1
                guard i < tokens.count else { return .failure(.missingValue("--provider")) }
                providerFlag = tokens[i]
            case "--prefix":
                i += 1
                guard i < tokens.count else { return .failure(.missingValue("--prefix")) }
                prefix = tokens[i]
            case "--theme":
                i += 1
                guard i < tokens.count else { return .failure(.missingValue("--theme")) }
                guard let named = CLITheme.named(tokens[i]) else { return .failure(.unknownTheme(tokens[i])) }
                theme = named
            case "--days":
                i += 1
                guard i < tokens.count else { return .failure(.missingValue("--days")) }
                guard let n = Int(tokens[i]), n >= 1 else { return .failure(.invalidDays(tokens[i])) }
                days = n
                rangeFlag = t
            case "--since", "--until":
                i += 1
                guard i < tokens.count else { return .failure(.missingValue(t)) }
                guard StatsRange.isDayKey(tokens[i]) else { return .failure(.invalidDay(flag: t, value: tokens[i])) }
                if t == "--since" { since = tokens[i] } else { until = tokens[i] }
                rangeFlag = t
            case "--csv":
                // The table name is optional, so only a known table is taken as its value.
                if i + 1 < tokens.count, let table = HistoryExportRenderer.CSVTable(rawValue: tokens[i + 1]) {
                    csv = table
                    i += 1
                } else {
                    csv = .days
                }
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
        if let rangeFlag, head != "stats" {
            return .failure(.unexpectedArgument(rangeFlag))
        }
        if csv != nil, head != "stats" {
            return .failure(.unexpectedArgument("--csv"))
        }

        func usageOptions(defaultFilter: ProviderFilter = .enabled) -> Result<UsageOptions, AUBParseError> {
            switch makeFilter(flag: providerFlag, positional: rest.first, defaultFilter: defaultFilter) {
            case .failure(let e): return .failure(e)
            case .success(let filter):
                if rest.count > 1 {
                    return .failure(.unexpectedArgument(rest[1]))
                }
                return .success(UsageOptions(filter: filter, json: json, noColor: noColor, cached: cached, theme: theme))
            }
        }

        switch head {
        case nil:
            if let providerFlag {
                switch parseProviderToken(providerFlag) {
                case .failure(let e): return .failure(e)
                case .success(let filter):
                    return .success(.usage(UsageOptions(
                        filter: filter, json: json, noColor: noColor, cached: cached, theme: theme
                    )))
                }
            }
            return .success(.usage(UsageOptions(
                filter: .enabled, json: json, noColor: noColor, cached: cached, theme: theme
            )))
        case "help":
            return .success(.help)
        case "version":
            return .success(.version)
        case "usage":
            return usageOptions().map { .usage($0) }
        case "quota", "limits":
            return usageOptions().map { .quota($0) }
        case "stats":
            // `--theme` is accepted and ignored: stats has one layout (V46).
            if json, csv != nil { return .failure(.unexpectedArgument("--csv")) }
            let format: StatsFormat = json ? .json : csv.map(StatsFormat.csv) ?? .text
            return usageOptions().map { opts in
                .stats(StatsOptions(
                    filter: opts.filter, days: days, since: since, until: until, noColor: noColor, format: format))
            }
        case "settings":
            return parseSettings(rest, json: json)
        case "themes":
            if let extra = rest.first { return .failure(.unexpectedArgument(extra)) }
            return .success(.themes(json: json, theme: theme))
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
                    filter: .one(id), json: json, noColor: noColor, cached: cached, theme: theme
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
        if token.hasPrefix("engine."), token.count > "engine.".count {
            return ProviderID(rawValue: token)
        }
        return ProviderID.allKnown.first { $0.rawValue == token }
    }
}

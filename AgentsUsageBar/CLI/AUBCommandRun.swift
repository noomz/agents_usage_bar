import Foundation
import Darwin

extension AUBCommand {

    @MainActor
    public static func run(arguments: [String]) async -> Int32 {
        switch parse(arguments) {
        case .failure(let err):
            fputs("error: \(err.description)\n", stderr)
            return 2
        case .success(let command):
            do {
                return try await execute(command)
            } catch let err as AUBParseError {
                fputs("error: \(err.description)\n", stderr)
                return 2
            } catch let err as CLISettings.SettingError {
                fputs("error: \(err.description)\n", stderr)
                return 2
            } catch let err as CLIInstaller.Error {
                fputs("error: \(err.description)\n", stderr)
                return 1
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
    }

    @MainActor
    private static func execute(_ command: AUBCommand) async throws -> Int32 {
        switch command {
        case .help:
            fputs(helpText + "\n", stdout)
            return 0
        case .version:
            fputs(versionString() + "\n", stdout)
            return 0
        case .settings(let action, let json):
            return try runSettings(action, json: json)
        case .themes(let json, let flag):
            let active = try resolveTheme(flag: flag)
            fputs(json ? try CLITheme.renderListJSON(active: active) : CLITheme.renderList(active: active), stdout)
            return 0
        case .install(let prefix):
            let installer = CLIInstaller()
            let path = try installer.install(prefix: prefix)
            fputs("Installed aub → \(path)\n", stdout)
            let dir = (path as NSString).deletingLastPathComponent
            if let hint = installer.pathHint(for: dir) {
                fputs("\(hint)\n", stdout)
            }
            return 0
        case .uninstall:
            try CLIInstaller().uninstall()
            fputs("Uninstalled aub symlinks that pointed at this app.\n", stdout)
            return 0
        case .usage(let opts):
            return try await runUsage(opts, quotaOnly: false)
        case .quota(let opts):
            return try await runUsage(opts, quotaOnly: true)
        case .stats(let opts):
            return try await runStats(opts)
        }
    }

    private static func runStats(_ opts: StatsOptions) async throws -> Int32 {
        let result = try await stats(opts, reader: HistoryReader(), owner: DayKeyOwner())
        fputs(result.text, result.code == 0 ? stdout : stderr)
        return result.code
    }

    /// Reads `history/` read-only (V19). No history prints one line and exits 0; a store
    /// that cannot be listed is an error with exit 1 (V46). The newest day file keeps today
    /// from going back (V4).
    static func stats(
        _ opts: StatsOptions,
        reader: HistoryReader,
        owner: DayKeyOwner
    ) async throws -> (text: String, code: Int32) {
        let keys: [String]
        do {
            keys = try await reader.dayKeys()
        } catch {
            let path = reader.directory.path(percentEncoded: false)
            return ("error: cannot read usage history at \(path): \(error.localizedDescription)\n", 1)
        }
        guard let newest = keys.last else {
            return (StatsTextRenderer.noHistory + "\n", 0)
        }
        owner.advanceNewest(to: newest)
        let range = try StatsRange.resolve(today: owner.today(), days: opts.days, since: opts.since, until: opts.until).get()
        let days = try await reader.days(in: range.keys[0]...range.keys[range.keys.count - 1])
        let color = CLIFormat.shouldColor(noColor: opts.noColor)
        switch opts.filter {
        case .one(let id):
            return (StatsTextRenderer.renderProvider(days, id: id, range: range, color: color), 0)
        case .enabled, .all:
            return (StatsTextRenderer.renderSummary(
                days, range: range, includeLocal: opts.filter == .all,
                order: UserDefaults.standard.aubProviderOrder, color: color), 0)
        }
    }

    /// `settings --json` is handled by parsing `--json` as a usage flag before
    /// the subcommand is identified. Re-read from the already-parsed command:
    /// callers that want JSON pass it via a dedicated settings list JSON path
    /// in `runSettings` when stdout is requested as JSON by wrapping execute.
    @MainActor
    private static func runSettings(_ action: SettingsAction, json: Bool) throws -> Int32 {
        _ = json
        let store = CLISettings()
        switch action {
        case .list:
            let rows = store.list()
            if json {
                var dict: [String: String] = [:]
                for row in rows { dict[row.key] = row.value }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(dict)
                fputs(String(decoding: data, as: UTF8.self) + "\n", stdout)
            } else {
                for row in rows {
                    fputs("\(row.key)=\(row.value)\n", stdout)
                }
            }
            return 0
        case .get(let key):
            switch store.get(key) {
            case .failure(let err): throw err
            case .success(let row):
                if json {
                    let data = try JSONEncoder().encode(["key": row.key, "value": row.value])
                    fputs(String(decoding: data, as: UTF8.self) + "\n", stdout)
                } else {
                    fputs("\(row.value)\n", stdout)
                }
                return 0
            }
        case .set(let key, let value):
            switch store.set(key, value: value) {
            case .failure(let err): throw err
            case .success(let result):
                fputs("\(result.key)=\(result.value)\n", stdout)
                if let warning = result.warning {
                    fputs("warning: \(warning)\n", stderr)
                }
                return 0
            }
        }
    }

    @MainActor
    private static func runUsage(_ opts: UsageOptions, quotaOnly: Bool) async throws -> Int32 {
        if opts.json {
            let report = await makeSession().fetch(filter: opts.filter, cached: opts.cached)
            let text = quotaOnly
                ? try UsageJSONRenderer.renderQuota(report)
                : try UsageJSONRenderer.renderUsage(report)
            fputs(text, stdout)
            return 0
        }
        // Resolve before fetching so a bad AUB_THEME fails fast; JSON never reads env/setting.
        let theme = try resolveTheme(flag: opts.theme).theme
        let report = await makeSession().fetch(filter: opts.filter, cached: opts.cached)
        let color = CLIFormat.shouldColor(noColor: opts.noColor)
        fputs(theme.render(report, view: quotaOnly ? .quota : .usage, color: color), stdout)
        return 0
    }

    private static func resolveTheme(flag: CLITheme?) throws -> CLITheme.Selection {
        try CLITheme.resolve(
            flag: flag,
            env: { ProcessInfo.processInfo.environment["AUB_THEME"] },
            setting: { CLISettings().storedCLITheme }
        ).get()
    }

    @MainActor
    private static func makeSession() -> CLIUsageSession {
        let clock: any Clock = SystemClock()
        let http: any HTTPClient = URLSessionHTTPClient()
        let localhostHTTP: any HTTPClient = URLSessionHTTPClient(timeoutSeconds: 2)
        let cache: any CacheStore
        do {
            cache = try FileCacheStore()
        } catch {
            cache = NoopCacheStore()
        }
        let preferences = UserPreferencesStore()
        let config = ConfigStore(env: ProcessInfoEnvReader()).load(preferences: preferences)
        let built = ProviderRegistryFactory.build(
            config: config,
            preferences: preferences,
            http: http,
            localhostHTTP: localhostHTTP,
            cache: cache,
            clock: clock
        )
        let enabled = preferences.providerEnabled
        return CLIUsageSession(
            providers: built.providers,
            placeholders: built.placeholders,
            cache: cache,
            clock: clock,
            isEnabled: { id in enabled[id] ?? true }
        )
    }

    private static func versionString() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "aub \(version) (\(build))"
    }
}

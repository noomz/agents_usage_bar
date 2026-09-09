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
        let report = await makeSession().fetch(filter: opts.filter, cached: opts.cached)
        let color = UsageTextRenderer.shouldColor(noColor: opts.noColor)
        if opts.json {
            let text = quotaOnly
                ? try UsageJSONRenderer.renderQuota(report)
                : try UsageJSONRenderer.renderUsage(report)
            fputs(text, stdout)
        } else {
            let text = quotaOnly
                ? UsageTextRenderer.renderQuota(report, color: color)
                : UsageTextRenderer.renderUsage(report, color: color)
            fputs(text, stdout)
        }
        return 0
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

import Foundation

/// Get/set the same UserDefaults knobs as Settings. Does not touch secrets or TOML.
public struct CLISettings {
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public enum SettingError: Error, Equatable, CustomStringConvertible, Sendable {
        case unknownKey(String)
        case invalidValue(key: String, value: String, expected: String)

        public var description: String {
            switch self {
            case .unknownKey(let k):
                return "unknown key '\(k)'. Try `aub settings`."
            case .invalidValue(let key, let value, let expected):
                return "invalid value '\(value)' for \(key); expected \(expected)"
            }
        }
    }

    public struct Entry: Equatable, Sendable {
        public let key: String
        public let value: String
        public let defaultValue: String
    }

    public struct SetResult: Equatable, Sendable {
        public let key: String
        public let value: String
        public let warning: String?
    }

    public func list() -> [Entry] {
        catalog.map { Entry(key: $0.cli, value: currentValue($0), defaultValue: $0.defaultValue) }
    }

    public func get(_ key: String) -> Result<Entry, SettingError> {
        guard let spec = spec(for: key) else { return .failure(.unknownKey(key)) }
        return .success(Entry(key: spec.cli, value: currentValue(spec), defaultValue: spec.defaultValue))
    }

    public func set(_ key: String, value: String) -> Result<SetResult, SettingError> {
        guard let spec = spec(for: key) else { return .failure(.unknownKey(key)) }
        switch spec.kind {
        case .interval:
            guard RefreshInterval.parse(value) != nil else {
                return .failure(.invalidValue(key: key, value: value, expected: "manual|1m|2m|5m|15m|30m"))
            }
            defaults.set(value, forKey: spec.defaultsKey)
            return .success(SetResult(key: spec.cli, value: value, warning: nil))
        case .threshold:
            guard let n = Double(value), n >= 0.50, n <= 0.95 else {
                return .failure(.invalidValue(key: key, value: value, expected: "number in 0.50…0.95"))
            }
            defaults.set(n, forKey: spec.defaultsKey)
            return .success(SetResult(key: spec.cli, value: formatThreshold(n), warning: nil))
        case .theme:
            guard AppTheme(rawValue: value) != nil else {
                return .failure(.invalidValue(key: key, value: value, expected: "light|dark|auto"))
            }
            defaults.set(value, forKey: spec.defaultsKey)
            return .success(SetResult(key: spec.cli, value: value, warning: nil))
        case .bool:
            guard let b = parseBool(value) else {
                return .failure(.invalidValue(key: key, value: value, expected: "true|false"))
            }
            defaults.set(b, forKey: spec.defaultsKey)
            let warning: String?
            if spec.cli == "open-at-login" {
                warning = "Login Items registration only happens in Settings; the flag was stored."
            } else {
                warning = nil
            }
            return .success(SetResult(key: spec.cli, value: b ? "true" : "false", warning: warning))
        case .claudeSource:
            guard ClaudeUsageSource(rawValue: value) != nil else {
                return .failure(.invalidValue(key: key, value: value, expected: "sessionReads|hook"))
            }
            defaults.set(value, forKey: spec.defaultsKey)
            return .success(SetResult(key: spec.cli, value: value, warning: nil))
        }
    }

    // MARK: - Catalog

    fileprivate struct Spec {
        enum Kind { case interval, threshold, theme, bool, claudeSource }
        let cli: String
        let defaultsKey: String
        let defaultValue: String
        let kind: Kind
    }

    private var catalog: [Spec] {
        var rows: [Spec] = [
            Spec(cli: "refresh-interval", defaultsKey: AUBDefaultsKey.refreshInterval, defaultValue: "5m", kind: .interval),
            Spec(cli: "threshold", defaultsKey: AUBDefaultsKey.threshold, defaultValue: "0.80", kind: .threshold),
            Spec(cli: "theme", defaultsKey: AUBDefaultsKey.theme, defaultValue: "auto", kind: .theme),
            Spec(cli: "pace-warnings", defaultsKey: AUBDefaultsKey.paceWarningsEnabled, defaultValue: "true", kind: .bool),
            Spec(cli: "reset-notifications", defaultsKey: AUBDefaultsKey.resetNotificationsEnabled, defaultValue: "true", kind: .bool),
            Spec(cli: "claude-source", defaultsKey: AUBDefaultsKey.claudeSource, defaultValue: "sessionReads", kind: .claudeSource),
            Spec(cli: "open-at-login", defaultsKey: AUBDefaultsKey.openAtLogin, defaultValue: "false", kind: .bool),
            Spec(cli: "has-seen-welcome", defaultsKey: AUBDefaultsKey.hasSeenWelcome, defaultValue: "false", kind: .bool),
        ]
        for id in ProviderID.allKnown {
            rows.append(Spec(
                cli: "provider.\(id.rawValue).enabled",
                defaultsKey: AUBDefaultsKey.providerEnabled(id),
                defaultValue: "true",
                kind: .bool
            ))
        }
        return rows
    }

    private func spec(for key: String) -> Spec? {
        catalog.first { $0.cli == key }
    }

    private func currentValue(_ spec: Spec) -> String {
        switch spec.kind {
        case .interval:
            return RefreshInterval.parse(defaults.string(forKey: spec.defaultsKey) ?? "")?.tomlString
                ?? spec.defaultValue
        case .threshold:
            if let n = defaults.object(forKey: spec.defaultsKey) as? Double {
                return formatThreshold(n)
            }
            return spec.defaultValue
        case .theme:
            return AppTheme(rawValue: defaults.string(forKey: spec.defaultsKey) ?? "")?.rawValue
                ?? spec.defaultValue
        case .claudeSource:
            return ClaudeUsageSource(rawValue: defaults.string(forKey: spec.defaultsKey) ?? "")?.rawValue
                ?? spec.defaultValue
        case .bool:
            if defaults.object(forKey: spec.defaultsKey) == nil { return spec.defaultValue }
            return defaults.bool(forKey: spec.defaultsKey) ? "true" : "false"
        }
    }

    private func formatThreshold(_ n: Double) -> String {
        String(format: "%.2f", n)
    }

    private func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
}

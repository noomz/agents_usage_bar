import Foundation

/// Which `aub` text view a theme renders.
public enum CLIView: Sendable, Equatable {
    case usage
    case quota
}

/// Built-in layout for `aub` terminal output. Static switch; no runtime loading.
public enum CLITheme: String, CaseIterable, Sendable {
    case compact
    case classic

    public static let defaultTheme: CLITheme = .compact

    /// `compact|classic` — the list every theme error names.
    public static let expectedNames = allCases.map(\.rawValue).joined(separator: "|")

    /// Case-insensitive lookup; canonical form is lowercase.
    public static func named(_ raw: String) -> CLITheme? {
        CLITheme(rawValue: raw.lowercased())
    }

    public var summary: String {
        switch self {
        case .compact: return "One row per provider with severity glyphs"
        case .classic: return "Original multi-line layout"
        }
    }

    public func render(_ report: UsageReport, view: CLIView, color: Bool) -> String {
        switch self {
        case .compact:
            return CompactTextRenderer.render(report, view: view, color: color, width: CompactTextRenderer.terminalWidth())
        case .classic:
            switch view {
            case .usage: return UsageTextRenderer.renderUsage(report, color: color)
            case .quota: return UsageTextRenderer.renderQuota(report, color: color)
            }
        }
    }
}

// MARK: - Selection

extension CLITheme {

    public enum Source: String, Sendable, Equatable {
        case flag, env, setting, `default`

        /// Text label in `aub themes` (`from AUB_THEME`); JSON uses `rawValue`.
        var label: String { self == .env ? "AUB_THEME" : rawValue }
    }

    public struct Selection: Sendable, Equatable {
        public let theme: CLITheme
        public let source: Source
    }

    /// `--theme` > `AUB_THEME` > `cli-theme` setting > `compact`. Lower sources
    /// are read only when no higher one won, so the closures stay unevaluated
    /// when a flag is given.
    public static func resolve(
        flag: CLITheme?,
        env: () -> String?,
        setting: () -> CLITheme?
    ) -> Result<Selection, AUBParseError> {
        if let flag { return .success(Selection(theme: flag, source: .flag)) }
        if let raw = env(), !raw.isEmpty {
            guard let theme = named(raw) else { return .failure(.unknownThemeEnv(raw)) }
            return .success(Selection(theme: theme, source: .env))
        }
        if let theme = setting() { return .success(Selection(theme: theme, source: .setting)) }
        return .success(Selection(theme: defaultTheme, source: .default))
    }

    /// `aub themes` text listing.
    public static func renderList(active: Selection) -> String {
        let width = allCases.map(\.rawValue.count).max() ?? 0
        var out = ""
        for theme in allCases {
            let mark = theme == active.theme ? "●" : " "
            let name = theme.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
            let suffix = theme == defaultTheme ? " (default)" : ""
            out += "\(mark) \(name)  \(theme.summary)\(suffix)\n"
        }
        out += "active: \(active.theme.rawValue) (from \(active.source.label))\n"
        return out
    }

    /// `aub themes --json`.
    public static func renderListJSON(active: Selection) throws -> String {
        struct Entry: Encodable { let name: String; let description: String; let `default`: Bool }
        struct Document: Encodable { let themes: [Entry]; let active: String; let source: String }
        let doc = Document(
            themes: allCases.map { Entry(name: $0.rawValue, description: $0.summary, default: $0 == defaultTheme) },
            active: active.theme.rawValue,
            source: active.source.rawValue
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(doc), as: UTF8.self) + "\n"
    }
}

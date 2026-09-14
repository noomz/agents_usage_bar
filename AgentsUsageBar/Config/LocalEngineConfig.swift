import Foundation

/// HTTP dialect a local custom engine speaks.
///
/// v1 only supports llama.cpp / llamafile (`/health` + `/v1/models` + `/slots`).
/// Unknown TOML `kind` values are skipped (D-18 fail-soft).
public enum LocalEngineKind: String, Sendable, Equatable {
    case llamacpp
}

/// User- or built-in local engine: a llama.cpp-compatible HTTP server that is
/// not Ollama, not LM Studio Express, and not the brew `[llamacpp]` row.
///
/// Discovered by executable path (`matchPath`) and/or an explicit `port`.
public struct LocalEngineConfig: Sendable, Equatable {
    public let id: ProviderID
    public let displayName: String
    public let enabled: Bool
    public let kind: LocalEngineKind
    /// Substring matched against the listening process executable path.
    /// Example: `"/.lmstudio/extensions/backends/"`.
    public let matchPath: String?
    /// Explicit HTTP port. Used when `matchPath` is nil, or as fallback when
    /// no matching process is found.
    public let port: Int?

    public init(
        id: ProviderID,
        displayName: String,
        enabled: Bool,
        kind: LocalEngineKind,
        matchPath: String?,
        port: Int?
    ) {
        self.id = id
        self.displayName = displayName
        self.enabled = enabled
        self.kind = kind
        self.matchPath = matchPath
        self.port = port
    }

    public func withEnabled(_ enabled: Bool) -> LocalEngineConfig {
        LocalEngineConfig(
            id: id,
            displayName: displayName,
            enabled: enabled,
            kind: kind,
            matchPath: matchPath,
            port: port
        )
    }

    /// Caption when no port could be resolved. Empty match+port is a
    /// discoverability hint; otherwise the row is simply not running.
    public var unresolvedPlaceholderMessage: String? {
        if (matchPath == nil || matchPath?.isEmpty == true), port == nil {
            return "Set [engine.\(id.engineSlug)] port or match_path in config.toml"
        }
        return nil
    }
}

extension LocalEngineConfig {
    /// Built-in LM Studio llama.cpp backend (not the Express server on :1234).
    public static let lmstudioLlamaCpp = LocalEngineConfig(
        id: .lmstudioLlamaCpp,
        displayName: "LM Studio llama.cpp",
        enabled: true,
        kind: .llamacpp,
        matchPath: "/.lmstudio/extensions/backends/",
        port: nil
    )

    public static let builtIns: [LocalEngineConfig] = [.lmstudioLlamaCpp]

    /// Parses `[engine.<slug>]` tables out of the TomlReader section map.
    ///
    /// Overlay: `[engine.lms-llamacpp]` updates the built-in. Any other slug
    /// becomes `ProviderID(rawValue: "engine.<slug>")`. Sections that collide
    /// with hosted/built-in provider ids (ollama, claude, …) are skipped.
    public static func parse(from toml: [String: [String: TomlValue]]) -> [LocalEngineConfig] {
        var engines = builtIns
        let reserved = Set(ProviderID.allKnown.map(\.rawValue))
            .subtracting(Set(builtIns.map { $0.id.rawValue }))

        for (section, keys) in toml {
            guard section.hasPrefix("engine.") else { continue }
            let slug = String(section.dropFirst("engine.".count))
            guard !slug.isEmpty, !slug.contains("."), !reserved.contains(slug) else { continue }

            let kind: LocalEngineKind
            if case .string(let raw) = keys["kind"] {
                guard let parsed = LocalEngineKind(rawValue: raw) else { continue }
                kind = parsed
            } else {
                kind = .llamacpp
            }

            let enabled: Bool
            if case .bool(let b) = keys["enabled"] {
                enabled = b
            } else {
                enabled = true
            }

            let name: String
            if case .string(let s) = keys["name"], !s.isEmpty {
                name = s
            } else if case .string(let s) = keys["display_name"], !s.isEmpty {
                name = s
            } else {
                name = slug.replacingOccurrences(of: "-", with: " ")
            }

            let matchPath: String?
            if case .string(let s) = keys["match_path"], !s.isEmpty {
                matchPath = s
            } else {
                matchPath = nil
            }

            let port: Int?
            if case .int(let i) = keys["port"], (1...65535).contains(i) {
                port = i
            } else {
                port = nil
            }

            if matchPath == nil, port == nil, engines.contains(where: { $0.id.rawValue == slug || $0.id.rawValue == "engine.\(slug)" }) == false {
                // Overlay of a built-in may omit match_path to only flip enabled.
                // Brand-new engines need at least one discovery key.
                if slug != ProviderID.lmstudioLlamaCpp.rawValue { continue }
            }

            let id: ProviderID
            if slug == ProviderID.lmstudioLlamaCpp.rawValue {
                id = .lmstudioLlamaCpp
            } else {
                id = ProviderID(rawValue: "engine.\(slug)")
            }

            let parsed = LocalEngineConfig(
                id: id,
                displayName: name,
                enabled: enabled,
                kind: kind,
                matchPath: matchPath ?? (id == .lmstudioLlamaCpp ? Self.lmstudioLlamaCpp.matchPath : nil),
                port: port
            )

            if let idx = engines.firstIndex(where: { $0.id == id }) {
                engines[idx] = parsed
            } else {
                engines.append(parsed)
            }
        }

        return engines
    }
}

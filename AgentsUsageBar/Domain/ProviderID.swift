/// Strongly-typed provider identifier.
/// Downstream plans (01.04, 01.05, 01.07) depend on the exact `rawValue` strings
/// defined as static constants — do not change them without a migration plan.
public struct ProviderID: Sendable, Hashable, RawRepresentable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ProviderID {
    /// OpenRouter — https://openrouter.ai
    /// Plans 01.04 and 01.05 use this constant as the key for HTTP fetching and cache storage.
    public static let openrouter = ProviderID(rawValue: "openrouter")

    /// Claude — Anthropic's Claude models via JSONL transcript files + OAuth quota API.
    /// Plan 02.04 uses this constant as the provider ID for `ClaudeJSONLProvider`.
    /// `displayHint` already returns "Claude" for this rawValue (Phase 1 declaration).
    public static let claude = ProviderID(rawValue: "claude")

    /// Codex — OpenAI Codex via local rollout JSONL files (`~/.codex/sessions/**`)
    /// with OAuth fallback. Plan 03-01 introduces this constant for use by
    /// `CodexRolloutScanner` / `CodexRolloutParser` / future `CodexJSONLProvider`.
    /// `displayHint` already returns "Codex" for this rawValue.
    public static let codex = ProviderID(rawValue: "codex")

    /// Gemini — Google Gemini via OAuth-personal flow against
    /// `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` +
    /// `:loadCodeAssist`. Plan 03-06 introduces this constant for the
    /// `GeminiOAuthProvider` actor. `displayHint` already returns "Gemini"
    /// for this rawValue.
    public static let gemini = ProviderID(rawValue: "gemini")

    /// Ollama — http://localhost:11434 (LOCAL-01). Plan 04-04 introduces this
    /// constant for `OllamaProvider`. `displayHint` already returns "Ollama"
    /// for this rawValue (Phase 1 declaration).
    public static let ollama = ProviderID(rawValue: "ollama")

    /// LM Studio — http://localhost:1234 by default, port overridable via
    /// `[lmstudio].port` in config.toml (LOCAL-02). Plan 04-05 introduces
    /// this constant for `LMStudioProvider`. `displayHint` already returns
    /// "LM Studio" for this rawValue.
    public static let lmstudio = ProviderID(rawValue: "lmstudio")

    /// llama.cpp / llamafile — port REQUIRED in `[llamacpp].port` in
    /// config.toml; no scanning (LOCAL-03). Plan 04-06 introduces this
    /// constant for `LlamaCppProvider`. `displayHint` already returns
    /// "llama.cpp" for this rawValue.
    public static let llamacpp = ProviderID(rawValue: "llamacpp")

    /// LM Studio's bundled llama.cpp backend (`~/.lmstudio/extensions/backends/**/llama-server`).
    /// Distinct from `.lmstudio` (Express on :1234) and from brew `.llamacpp`.
    public static let lmstudioLlamaCpp = ProviderID(rawValue: "lms-llamacpp")

    /// Plan 04-01 — built-in localhost-runtime IDs.
    /// Custom `[engine.<slug>]` rows are also local via `isLocalRuntime`.
    public static let localIDs: Set<ProviderID> = [.ollama, .lmstudio, .llamacpp, .lmstudioLlamaCpp]

    /// True for built-in local runtimes and user-defined `[engine.*]` rows.
    public var isLocalRuntime: Bool {
        Self.localIDs.contains(self) || rawValue.hasPrefix("engine.")
    }

    /// Slug used in `[engine.<slug>]` TOML and placeholder copy.
    public var engineSlug: String {
        if rawValue.hasPrefix("engine.") {
            return String(rawValue.dropFirst("engine.".count))
        }
        return rawValue
    }

    /// Grok — xAI Grok Build TUI via `~/.grok/auth.json` +
    /// `GET {cli-chat-proxy}/billing?format=credits`. Quota/credits only;
    /// local session files do not persist billed tokens.
    public static let grok = ProviderID(rawValue: "grok")

    /// Plan 05-02 — Ordered array of all known providers in display order.
    /// Used by `UserPreferencesStore.loadAll()` and `SettingsProvidersTab` row enumeration.
    public static let allKnown: [ProviderID] = [
        .openrouter, .claude, .codex, .gemini, .grok, .ollama, .lmstudio, .lmstudioLlamaCpp, .llamacpp
    ]

    /// User-set provider order (`provider-order`, SPEC V31): ids listed in
    /// `preference` first, in that order; then unlisted ids in `allKnown` order;
    /// then everything else (`engine.*`) alphabetically by raw value. Listed ids
    /// with no matching item are skipped.
    public static func ordered<T>(_ items: [T], id: (T) -> ProviderID, preference: [ProviderID]) -> [T] {
        func key(_ pid: ProviderID) -> (Int, Int, String) {
            if let i = preference.firstIndex(of: pid) { return (0, i, "") }
            if let i = allKnown.firstIndex(of: pid) { return (1, i, "") }
            return (2, 0, pid.rawValue)
        }
        return items
            .map { (key(id($0)), $0) }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    /// Human-readable display hint for this provider.
    ///
    /// Used by `ThresholdEngine` to populate `NotificationDecision.displayName` (B3),
    /// which `UNNotificationManager` joins into the coalesced notification body.
    public var displayHint: String {
        switch rawValue {
        case "openrouter": return "OpenRouter"
        case "claude":     return "Claude"
        case "codex":      return "Codex"
        case "gemini":     return "Gemini"
        case "grok":       return "Grok"
        case "ollama":     return "Ollama"
        case "lmstudio":   return "LM Studio"
        case "lms-llamacpp": return "LM Studio llama.cpp"
        case "llamacpp":   return "llama.cpp"
        default:
            if rawValue.hasPrefix("engine.") {
                return engineSlug
                    .split(separator: "-")
                    .map { $0.capitalized }
                    .joined(separator: " ")
            }
            return rawValue.capitalized
        }
    }
}

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

    /// Plan 04-01 — Phase 4 lookup constant. The three localhost-runtime IDs
    /// whose `ProviderCapabilities.isLocal == true`.
    ///
    /// `ProviderRowView` (Plan 04-07) keys on this `Set` when the provider
    /// registry isn't available in the view environment.
    public static let localIDs: Set<ProviderID> = [.ollama, .lmstudio, .llamacpp]

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
        case "ollama":     return "Ollama"
        case "lmstudio":   return "LM Studio"
        case "llamacpp":   return "llama.cpp"
        default:           return rawValue.capitalized
        }
    }
}

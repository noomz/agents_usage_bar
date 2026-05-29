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

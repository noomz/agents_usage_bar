import Foundation

/// Pure URL lookup table for the per-provider "Open dashboard" affordance (D-13 / D-14 / UI-11).
///
/// Plan 03-07 introduces this namespace to surface each provider's web-console
/// URL via the trailing-icon button on `ProviderRowView`. The mapping is
/// deliberately hard-coded (D-14 — no config knob in v1) and HTTPS-only so the
/// Hardened Runtime + ATS posture stays intact.
///
/// URLs (verbatim, D-14):
///   - `openrouter` → `https://openrouter.ai/credits`
///   - `claude`     → `https://console.anthropic.com/settings/usage`
///   - `codex`      → `https://platform.openai.com/usage`
///   - `gemini`     → `https://aistudio.google.com/u/0/usage`
///     The `/u/0/` segment pins to the first signed-in Google account so the
///     dashboard never lands the user on Google's account-picker (verified via
///     RESEARCH §"Dashboard URLs").
///
/// Returns `nil` for any other rawValue — local LLM rows (Ollama / LM Studio /
/// llama.cpp) and any future provider whose dashboard URL has not yet been
/// reviewed. The caller's button is then `.disabled(url == nil)`.
public enum ProviderDashboardURL {

    /// OpenRouter credits dashboard.
    public static let openrouter = URL(string: "https://openrouter.ai/credits")!

    /// Anthropic Console usage dashboard for Claude.
    public static let claude = URL(string: "https://console.anthropic.com/settings/usage")!

    /// OpenAI Platform usage dashboard for Codex.
    public static let codex = URL(string: "https://platform.openai.com/usage")!

    /// Google AI Studio usage dashboard for Gemini. The `/u/0/` segment pins
    /// the first signed-in Google account so the user never lands on the
    /// account-picker page (RESEARCH §"Dashboard URLs").
    public static let gemini = URL(string: "https://aistudio.google.com/u/0/usage")!

    /// Returns the dashboard URL for `providerID`, or `nil` when no mapping
    /// exists (out-of-scope providers — local LLMs, unknown future IDs).
    ///
    /// Switching on `rawValue` rather than direct constant comparison keeps the
    /// lookup safe against `ProviderID` constants that may be added at a
    /// different layer (the `nil` arm is the safe default for any unknown ID).
    public static func lookup(_ providerID: ProviderID) -> URL? {
        switch providerID.rawValue {
        case "openrouter": return openrouter
        case "claude":     return claude
        case "codex":      return codex
        case "gemini":     return gemini
        default:           return nil
        }
    }
}

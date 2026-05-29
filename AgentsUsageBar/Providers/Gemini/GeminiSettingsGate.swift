import Foundation

// MARK: - GeminiSettingsGate
//
// RESEARCH correction #2:
//   The live `~/.gemini/settings.json` keypath is NESTED at
//   `security.auth.selectedType` — NOT the flat single-key shape that
//   CONTEXT.md / REQUIREMENTS.md describe.
//
// CRITICAL: do NOT add a fall-through to the flat shape. RESEARCH correction
// #2 says the flat shape does not exist in live files; falling through would
// hide a regression in this gate and silently disable Gemini for every user.
//
// Returns `false` (Gemini gated off) for every degenerate input — missing
// file, malformed JSON, missing key, wrong type, wrong case, any value
// other than the exact case-sensitive string `"oauth-personal"`. Plan 03-06's
// composition root reads this and skips registering the provider entirely.
//
// Source: gemini-cli, CodexBar GeminiStatusProbe (`json["security"]["auth"]["selectedType"]`).

/// Reads `~/.gemini/settings.json` and decides whether the Gemini provider
/// is gated ON for OAuth-personal usage (the only supported v1 auth path).
///
/// Single static surface; no state. Never throws — `false` is the unambiguous
/// "Gemini gated off" signal.
public enum GeminiSettingsGate {

    /// Default relative path under `NSHomeDirectory()` — `/.gemini/settings.json`.
    public static let defaultSettingsRelPath = "/.gemini/settings.json"

    /// Returns `true` iff the file exists, parses as a JSON object, AND the
    /// nested keypath `security.auth.selectedType` equals exactly the case-
    /// sensitive string `"oauth-personal"`.
    ///
    /// - Parameters:
    ///   - settingsPath: Override for the settings.json URL (tests inject
    ///     a temp-dir URL); `nil` uses the default `~/.gemini/settings.json`.
    ///   - fileManager: Reserved for symmetry with other loaders; not used
    ///     directly (`Data(contentsOf:)` performs the file read).
    public static func isOAuthPersonal(
        settingsPath: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        let url = settingsPath
            ?? URL(fileURLWithPath: NSHomeDirectory() + Self.defaultSettingsRelPath)

        guard let data = try? Data(contentsOf: url) else {
            return false
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }

        // RESEARCH correction #2: NESTED keypath — security.auth.selectedType
        // (NOT flat). Do not add a fall-through to the flat shape under any
        // circumstance; the regression-guard test will fail if you do.
        guard
            let security = json["security"] as? [String: Any],
            let auth = security["auth"] as? [String: Any],
            let selectedType = auth["selectedType"] as? String
        else {
            return false
        }

        return selectedType == "oauth-personal"
    }
}

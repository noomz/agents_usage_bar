import Foundation

// MARK: - OnboardingCopyError

/// Errors thrown by `OnboardingCopy.loadBundled()`.
public enum OnboardingCopyError: Error, Sendable {
    /// `Resources/Onboarding/providers.json` not found in the app bundle.
    case bundleResourceMissing
    /// JSON decoding failed.
    case decodeFailed(Error)
}

// MARK: - ProviderOnboardingInfo

/// Per-provider copy for the "How to enable" help panels.
///
/// Decoded from a single entry in `Resources/Onboarding/providers.json`.
///
/// SEC-04 compliance: `envSnippet` and `tomlSnippet` MUST use `<placeholder>` tokens —
/// never real-looking API key patterns (`sk-or-`, `sk-proj-`, `AIzaSy`, etc.).
/// Enforced by `OnboardingCopyTests.loadBundled_noRealLookingApiKeys`.
public struct ProviderOnboardingInfo: Decodable, Sendable {
    /// Matches `ProviderID.rawValue` (e.g. `"openrouter"`, `"claude"`).
    public let providerID: String
    /// Human-readable provider name (e.g. `"OpenRouter"`).
    public let displayName: String
    /// Short description of what signal the detection probe looks for.
    public let detectionDescription: String
    /// Environment-variable snippet (copy-able by the user).
    public let envSnippet: String
    /// Note shown below the env snippet (e.g. restart requirement).
    public let envNote: String
    /// config.toml snippet (copy-able by the user).
    public let tomlSnippet: String
    /// Note shown below the TOML snippet.
    public let tomlNote: String
    /// Optional link to the provider's documentation.
    public let docsURL: String?
    // Lenient: unknown future fields are silently ignored by JSONDecoder's default behavior.
}

// MARK: - OnboardingCopy

/// Root container for all provider onboarding entries.
///
/// Loaded from `Resources/Onboarding/providers.json` at runtime via `loadBundled()`.
/// Mirrors the `ClaudeModelPricing.loadBundled()` pattern exactly (Research Q10).
public struct OnboardingCopy: Decodable, Sendable {
    /// Ordered list of provider onboarding entries.
    public let providers: [ProviderOnboardingInfo]

    /// Loads `providers.json` from the app bundle.
    ///
    /// The file lives at `Resources/Onboarding/providers.json` inside the app bundle.
    /// Uses `Bundle.main.url(forResource:withExtension:subdirectory:)` — same pattern
    /// as `ClaudeModelPricing.loadBundled()` (Phase 2 P-02 / `ClaudeModelPricing.swift:79`).
    ///
    /// - Throws: `OnboardingCopyError.bundleResourceMissing` if the file is absent,
    ///   or `OnboardingCopyError.decodeFailed(_:)` if JSON decoding fails.
    public static func loadBundled() throws -> OnboardingCopy {
        guard let url = Bundle.main.url(
            forResource: "providers",
            withExtension: "json",
            subdirectory: "Onboarding"
        ) else {
            throw OnboardingCopyError.bundleResourceMissing
        }
        do {
            let data = try Data(contentsOf: url)
            // NOTE: Do NOT use .convertFromSnakeCase — JSON keys are already camelCase
            // (providerID, displayName, envSnippet, etc.) matching the Swift property names.
            return try JSONDecoder().decode(OnboardingCopy.self, from: data)
        } catch {
            throw OnboardingCopyError.decodeFailed(error)
        }
    }
}

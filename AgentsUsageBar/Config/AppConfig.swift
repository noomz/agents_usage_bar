import Foundation

// MARK: - AppConfig

/// Decoded configuration for the app.
///
/// D-15 defaults: `refreshInterval = .m5`, `threshold = 0.80`.
/// All fields are immutable value types — rebuild via `ConfigStore.load()` when needed.
///
/// Equatable note: do not print `AppConfig` in test failure messages —
/// `Secret.description` still redacts, so `#expect` diffs show `"<redacted>"` not the real key.
public struct AppConfig: Sendable, Equatable {
    public let refreshInterval: RefreshInterval
    public let threshold: Double
    public let openrouter: OpenRouterConfig

    public init(
        refreshInterval: RefreshInterval,
        threshold: Double,
        openrouter: OpenRouterConfig
    ) {
        self.refreshInterval = refreshInterval
        self.threshold = threshold
        self.openrouter = openrouter
    }

    /// Built-in defaults (D-15).
    ///
    /// Used as the baseline before env and TOML overrides are applied.
    public static let defaults = AppConfig(
        refreshInterval: .m5,
        threshold: 0.80,
        openrouter: OpenRouterConfig(
            apiKey: nil,
            apiURL: URL(string: "https://openrouter.ai/api/v1")!,
            httpReferer: nil,
            xTitle: "Agents Usage Bar",
            enabled: true
        )
    )
}

// MARK: - OpenRouterConfig

/// Per-provider configuration for OpenRouter (ROUTER-04).
///
/// `apiKey` is `nil` when neither env nor TOML supplies a key — the provider row
/// will display a "Not configured" placeholder message (D-15 / plan 01.04 contract).
public struct OpenRouterConfig: Sendable, Equatable {
    /// Bearer credential. `nil` means "not configured."
    /// Wrapped in `Secret` to prevent accidental log exposure (SEC-01).
    public let apiKey: Secret?

    /// API base URL. Default: `https://openrouter.ai/api/v1` (ROUTER-04).
    public let apiURL: URL

    /// Optional `HTTP-Referer` header value (ROUTER-04).
    public let httpReferer: String?

    /// `X-Title` header value. Default: `"Agents Usage Bar"` (ROUTER-04).
    public let xTitle: String

    /// Whether the OpenRouter provider is enabled. Default: `true`.
    public let enabled: Bool

    public init(
        apiKey: Secret?,
        apiURL: URL,
        httpReferer: String?,
        xTitle: String,
        enabled: Bool
    ) {
        self.apiKey = apiKey
        self.apiURL = apiURL
        self.httpReferer = httpReferer
        self.xTitle = xTitle
        self.enabled = enabled
    }
}

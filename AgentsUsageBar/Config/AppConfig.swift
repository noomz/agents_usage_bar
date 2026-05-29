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
    /// Per-provider configuration for OpenAI Codex (Plan 03-08 — CODEX-01..04).
    public let codex: CodexConfig
    /// Per-provider configuration for Google Gemini OAuth-personal (Plan 03-08 — GEMINI-02..04).
    public let gemini: GeminiConfig

    public init(
        refreshInterval: RefreshInterval,
        threshold: Double,
        openrouter: OpenRouterConfig,
        codex: CodexConfig,
        gemini: GeminiConfig
    ) {
        self.refreshInterval = refreshInterval
        self.threshold = threshold
        self.openrouter = openrouter
        self.codex = codex
        self.gemini = gemini
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
        ),
        codex: CodexConfig(
            enabled: true,
            bearerOverride: nil,
            sessionWindowDays: 2
        ),
        gemini: GeminiConfig(
            enabled: true,
            projectIDOverride: nil
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

// MARK: - CodexConfig (Plan 03-08)

/// Per-provider configuration for OpenAI Codex (CODEX-01..04).
///
/// Plan 03-08 adds the `[codex]` TOML section + the `CODEX_BEARER_TOKEN`
/// env override. Composition root (`AppDependencies.makeProduction`) consults
/// `enabled` to decide whether to register `CodexJSONLProvider` at all.
///
/// `bearerOverride` is an advanced testing knob — exclusively read from env
/// (NOT TOML — bearer in TOML would surface in `cat config.toml` and leak
/// into shell history). Per STATE #22, empty-env strings are treated as
/// absent; `ConfigStore` enforces this rule.
///
/// `sessionWindowDays` is hard-coded to 2 in v1 per 03-CONTEXT "Deferred
/// Ideas — Configurable session_window_days"; the field exists for future
/// expansion but `ConfigStore` does NOT expose a TOML knob in v1.
public struct CodexConfig: Sendable, Equatable {
    /// Whether the Codex provider is enabled. Default: `true`.
    /// Set to `false` via `[codex] enabled = false` in `config.toml`.
    public let enabled: Bool

    /// Optional bearer override (env `CODEX_BEARER_TOKEN`). Wrapped in
    /// `Secret` to prevent accidental log exposure (SEC-01). NOT exposed
    /// in `[codex]` TOML — env-only, by design.
    public let bearerOverride: Secret?

    /// Days of session-rollout history to scan (today + N-1 backwards).
    /// Hard-coded to `2` in v1 — field exists for future expansion only.
    public let sessionWindowDays: Int

    public init(
        enabled: Bool,
        bearerOverride: Secret?,
        sessionWindowDays: Int
    ) {
        self.enabled = enabled
        self.bearerOverride = bearerOverride
        self.sessionWindowDays = sessionWindowDays
    }
}

// MARK: - GeminiConfig (Plan 03-08)

/// Per-provider configuration for Google Gemini OAuth-personal (GEMINI-02..04).
///
/// Plan 03-08 adds the `[gemini]` TOML section + the `GEMINI_PROJECT_ID`
/// env override. Composition root (`AppDependencies.makeProduction`) consults
/// `enabled` to decide whether to register `GeminiOAuthProvider` at all; the
/// settings-gate check (`GeminiSettingsGate.isOAuthPersonal()`) is the second
/// gate that must also pass before the provider registers.
///
/// `projectIDOverride` lets advanced users bypass the loadCodeAssist project
/// capture by pinning a known Cloud project ID via env. It is NOT credential
/// material — exposed as plain `String?` (not `Secret`).
public struct GeminiConfig: Sendable, Equatable {
    /// Whether the Gemini provider is enabled. Default: `true`.
    /// Set to `false` via `[gemini] enabled = false` in `config.toml`.
    public let enabled: Bool

    /// Optional Cloud project ID override (env `GEMINI_PROJECT_ID`). Bypasses
    /// the v1internal:loadCodeAssist project-capture flow. NOT credential
    /// material — exposed as plain `String?`.
    public let projectIDOverride: String?

    public init(
        enabled: Bool,
        projectIDOverride: String?
    ) {
        self.enabled = enabled
        self.projectIDOverride = projectIDOverride
    }
}

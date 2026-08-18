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
    /// Per-provider configuration for xAI Grok Build TUI billing.
    public let grok: GrokConfig
    /// Per-provider configuration for Ollama localhost runtime (Plan 04-02 — LOCAL-01).
    public let ollama: OllamaConfig
    /// Per-provider configuration for LM Studio localhost runtime (Plan 04-02 — LOCAL-02).
    public let lmstudio: LMStudioConfig
    /// Per-provider configuration for llama.cpp / llamafile localhost runtime (Plan 04-02 — LOCAL-03).
    public let llamacpp: LlamaCppConfig

    public init(
        refreshInterval: RefreshInterval,
        threshold: Double,
        openrouter: OpenRouterConfig,
        codex: CodexConfig,
        gemini: GeminiConfig,
        grok: GrokConfig,
        ollama: OllamaConfig,
        lmstudio: LMStudioConfig,
        llamacpp: LlamaCppConfig
    ) {
        self.refreshInterval = refreshInterval
        self.threshold = threshold
        self.openrouter = openrouter
        self.codex = codex
        self.gemini = gemini
        self.grok = grok
        self.ollama = ollama
        self.lmstudio = lmstudio
        self.llamacpp = llamacpp
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
        ),
        grok: GrokConfig(
            enabled: true,
            apiKey: nil,
            apiURL: URL(string: "https://cli-chat-proxy.grok.com/v1")!
        ),
        ollama: OllamaConfig(enabled: true),
        lmstudio: LMStudioConfig(enabled: true, port: 1234),
        llamacpp: LlamaCppConfig(enabled: true, port: nil)
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

extension OpenRouterConfig {
    /// Returns a copy of this config with the `enabled` flag replaced.
    /// Plan 05-02: used by `ConfigStore.load(preferences:)` to apply UserDefaults overlay (D-02).
    func withEnabled(_ enabled: Bool) -> OpenRouterConfig {
        OpenRouterConfig(apiKey: apiKey, apiURL: apiURL, httpReferer: httpReferer, xTitle: xTitle, enabled: enabled)
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

extension CodexConfig {
    /// Returns a copy of this config with the `enabled` flag replaced.
    /// Plan 05-02: used by `ConfigStore.load(preferences:)` to apply UserDefaults overlay (D-02).
    func withEnabled(_ enabled: Bool) -> CodexConfig {
        CodexConfig(enabled: enabled, bearerOverride: bearerOverride, sessionWindowDays: sessionWindowDays)
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

extension GeminiConfig {
    /// Returns a copy of this config with the `enabled` flag replaced.
    /// Plan 05-02: used by `ConfigStore.load(preferences:)` to apply UserDefaults overlay (D-02).
    func withEnabled(_ enabled: Bool) -> GeminiConfig {
        GeminiConfig(enabled: enabled, projectIDOverride: projectIDOverride)
    }
}

// MARK: - GrokConfig

/// Per-provider configuration for xAI Grok Build TUI billing.
///
/// `[grok] enabled` and `[grok] api_url` are TOML knobs.
/// `XAI_API_KEY` is env-only (not TOML) — the normal path is `~/.grok/auth.json`.
public struct GrokConfig: Sendable, Equatable {
    /// Whether the Grok provider is enabled. Default: `true`.
    public let enabled: Bool

    /// Optional API-key fallback (`XAI_API_KEY`). Env-only. Wrapped in `Secret`.
    public let apiKey: Secret?

    /// CLI chat-proxy base URL. Default: `https://cli-chat-proxy.grok.com/v1`.
    /// Override via `GROK_CLI_CHAT_PROXY_BASE_URL` or `[grok] api_url`.
    public let apiURL: URL

    public init(enabled: Bool, apiKey: Secret?, apiURL: URL) {
        self.enabled = enabled
        self.apiKey = apiKey
        self.apiURL = apiURL
    }
}

extension GrokConfig {
    func withEnabled(_ enabled: Bool) -> GrokConfig {
        GrokConfig(enabled: enabled, apiKey: apiKey, apiURL: apiURL)
    }
}

// MARK: - OllamaConfig (Plan 04-02)

/// Per-provider configuration for the Ollama localhost runtime (LOCAL-01).
///
/// The well-known port 11434 is hard-coded in `OllamaProvider` (Plan 04-04) —
/// no port override is required or supported here per CONTEXT Discretion
/// §"TOML schema additions": Ollama always probes the well-known port.
///
/// `enabled = true` by default — Ollama is probed unconditionally unless the
/// user sets `[ollama] enabled = false` in `config.toml`.
public struct OllamaConfig: Sendable, Equatable {
    /// Whether the Ollama provider is enabled. Default: `true`.
    /// Set to `false` via `[ollama] enabled = false` in `config.toml`.
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

// MARK: - LMStudioConfig (Plan 04-02)

/// Per-provider configuration for the LM Studio localhost runtime (LOCAL-02).
///
/// `port` defaults to 1234 (LM Studio's well-known default) and is overridable
/// via `[lmstudio] port = <int>` in `config.toml` for users running LM Studio
/// on a non-default port. Mirrors the STATE #87 precedent for `CodexConfig`.
public struct LMStudioConfig: Sendable, Equatable {
    /// Whether the LM Studio provider is enabled. Default: `true`.
    public let enabled: Bool

    /// HTTP port LM Studio listens on. Default: `1234`.
    /// Override via `[lmstudio] port = <int>` in `config.toml`.
    public let port: Int

    public init(enabled: Bool, port: Int) {
        self.enabled = enabled
        self.port = port
    }
}

// MARK: - LlamaCppConfig (Plan 04-02)

/// Per-provider configuration for the llama.cpp / llamafile localhost runtime (LOCAL-03).
///
/// `port` is `nil` by default — the user MUST set `[llamacpp] port = <int>` in
/// `config.toml` to activate the live provider row. When `port == nil`, Plan 04-08
/// seeds the D-04 discoverability placeholder row instead of registering a live actor.
/// This implements LOCAL-03's "no port scanning" invariant: the app never probes a
/// port it was not explicitly given.
public struct LlamaCppConfig: Sendable, Equatable {
    /// Whether the llama.cpp provider is enabled. Default: `true`.
    /// Even when `true`, the row only activates when `port != nil`.
    public let enabled: Bool

    /// HTTP port llama.cpp / llamafile listens on. `nil` means "not configured."
    /// REQUIRED in `config.toml` to register a live provider row (LOCAL-03 — no scanning).
    /// When `nil`, Plan 04-08 seeds the D-04 placeholder with the discoverability subtitle.
    public let port: Int?

    public init(enabled: Bool, port: Int?) {
        self.enabled = enabled
        self.port = port
    }
}

// MARK: - Plan 05-02 withEnabled() helpers

extension OllamaConfig {
    /// Returns a copy of this config with the `enabled` flag replaced.
    /// Plan 05-02: used by `ConfigStore.load(preferences:)` to apply UserDefaults overlay (D-02).
    func withEnabled(_ enabled: Bool) -> OllamaConfig {
        OllamaConfig(enabled: enabled)
    }
}

extension LMStudioConfig {
    /// Returns a copy of this config with the `enabled` flag replaced.
    /// Plan 05-02: used by `ConfigStore.load(preferences:)` to apply UserDefaults overlay (D-02).
    func withEnabled(_ enabled: Bool) -> LMStudioConfig {
        LMStudioConfig(enabled: enabled, port: port)
    }
}

extension LlamaCppConfig {
    /// Returns a copy of this config with the `enabled` flag replaced.
    /// Plan 05-02: used by `ConfigStore.load(preferences:)` to apply UserDefaults overlay (D-02).
    func withEnabled(_ enabled: Bool) -> LlamaCppConfig {
        LlamaCppConfig(enabled: enabled, port: port)
    }
}

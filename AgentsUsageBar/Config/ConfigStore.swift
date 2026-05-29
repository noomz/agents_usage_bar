import Foundation
import os.log

/// CONFIG SOURCES (precedence: env > toml > defaults, per D-17):
///   1. ProcessInfo.environment via EnvReader (CFG-01: env vars; CFG-06 anti-feature: ONLY this source for env)
///   2. ~/.config/agents-usage-bar/config.toml via TomlReader (CFG-02; D-19 location)
///   3. AppConfig.defaults (D-15 defaults: refresh_interval=5m, threshold=0.80)
///
/// SEC-05 / CFG-06 ANTI-FEATURE — DO NOT IMPLEMENT:
///   - NO reads of ~/.zshrc, ~/.bashrc, ~/.config/fish/config.fish, or any shell rc file.
///   - NO `source` chain following. NO command execution. The env reader is ProcessInfo.environment ONLY.
///   - The CI grep step in Plan 01.08 will assert no `.zshrc`, `.bashrc`, `fish/config.fish` literal
///     strings appear in this file.
///
/// SEC-03 NOTE (deferred to Phase 6):
///   - `chmod 0600` creation enforcement and world-readable warning are Phase 6 (SEC-03).
///     Plan 01.03 only reads the file at the D-19 path; it never creates or modifies it.
public final class ConfigStore: @unchecked Sendable {

    // MARK: - Stored state

    private let env: any EnvReader
    private let tomlPath: URL
    private let logger = AppLogger.logger(category: "config")

    // MARK: - Init

    /// Creates a `ConfigStore`.
    ///
    /// - Parameters:
    ///   - env: Environment variable source. Defaults to `ProcessInfoEnvReader()` (production).
    ///          Pass a `DictionaryEnvReader` in tests for deterministic control.
    ///   - tomlPath: Path to the config TOML file. When `nil`, defaults to
    ///               `~/.config/agents-usage-bar/config.toml` (D-19).
    public init(env: any EnvReader = ProcessInfoEnvReader(), tomlPath: URL? = nil) {
        self.env = env
        self.tomlPath = tomlPath ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: ".config/agents-usage-bar/config.toml")
    }

    // MARK: - Public API

    /// Loads and resolves the merged configuration.
    ///
    /// Precedence: env > config.toml > `AppConfig.defaults` (D-17).
    ///
    /// Safe to call multiple times — reads env and file on every call (no caching).
    /// Never throws; invalid TOML lines are logged and skipped (D-18 fail-soft).
    public func load() -> AppConfig {
        // 1. Read TOML file (nil if absent or unreadable — fail-soft)
        let tomlText = try? String(contentsOf: tomlPath, encoding: .utf8)
        let toml = tomlText.map { TomlReader.parse($0, logger: logger) } ?? [:]

        let topLevel = toml[""] ?? [:]
        let orSection = toml["openrouter"] ?? [:]
        // Plan 03-08 — new per-provider sections.
        let codexSection = toml["codex"] ?? [:]
        let geminiSection = toml["gemini"] ?? [:]

        let defaults = AppConfig.defaults

        // 2. Resolve each field: env > toml > default

        // --- apiKey (OPENROUTER_API_KEY) ---
        let apiKey: Secret?
        if let envKey = env.value(forKey: "OPENROUTER_API_KEY") {
            apiKey = Secret(envKey)
        } else if case .string(let s) = orSection["api_key"] {
            apiKey = Secret(s)
        } else {
            apiKey = nil
        }

        // --- apiURL (OPENROUTER_API_URL) ---
        let apiURL: URL
        if let envURL = env.value(forKey: "OPENROUTER_API_URL"),
           let parsed = URL(string: envURL) {
            apiURL = parsed
        } else if case .string(let s) = orSection["api_url"],
                  let parsed = URL(string: s) {
            apiURL = parsed
        } else {
            apiURL = defaults.openrouter.apiURL
        }

        // Log warning if env URL was present but invalid
        if let envURLRaw = env.value(forKey: "OPENROUTER_API_URL"),
           URL(string: envURLRaw) == nil {
            logger.warning("config: OPENROUTER_API_URL value is not a valid URL — using default")
        }

        // --- httpReferer (OPENROUTER_HTTP_REFERER) ---
        let httpReferer: String?
        if let envRef = env.value(forKey: "OPENROUTER_HTTP_REFERER") {
            httpReferer = envRef
        } else if case .string(let s) = orSection["http_referer"] {
            httpReferer = s
        } else {
            httpReferer = nil
        }

        // --- xTitle (OPENROUTER_X_TITLE) ---
        let xTitle: String
        if let envTitle = env.value(forKey: "OPENROUTER_X_TITLE") {
            xTitle = envTitle
        } else if case .string(let s) = orSection["x_title"] {
            xTitle = s
        } else {
            xTitle = defaults.openrouter.xTitle
        }

        // --- enabled (toml only; no env override in Phase 1) ---
        let enabled: Bool
        if case .bool(let b) = orSection["enabled"] {
            enabled = b
        } else {
            enabled = defaults.openrouter.enabled
        }

        // --- refreshInterval (toml only; no env override in Phase 1) ---
        let refreshInterval: RefreshInterval
        if case .string(let s) = topLevel["refresh_interval"],
           let parsed = RefreshInterval.parse(s) {
            refreshInterval = parsed
        } else {
            refreshInterval = defaults.refreshInterval
        }

        // --- threshold (toml only; no env override in Phase 1) ---
        let threshold: Double
        if case .double(let d) = topLevel["threshold"] {
            threshold = d
        } else if case .int(let i) = topLevel["threshold"] {
            threshold = Double(i)
        } else {
            threshold = defaults.threshold
        }

        // --- Plan 03-08 — codex section (env > toml > defaults) ---

        // codex.enabled: TOML only (no env override).
        let codexEnabled: Bool
        if case .bool(let b) = codexSection["enabled"] {
            codexEnabled = b
        } else {
            codexEnabled = defaults.codex.enabled
        }

        // codex.bearerOverride: env CODEX_BEARER_TOKEN ONLY (NOT TOML —
        // bearer in TOML would surface in shell history; STATE #22 empty-
        // env-treated-as-absent applies).
        let codexBearer: Secret?
        if let envBearer = env.value(forKey: "CODEX_BEARER_TOKEN") {
            codexBearer = Secret(envBearer)
        } else {
            codexBearer = nil
        }

        // codex.sessionWindowDays: hard-coded 2 in v1 per 03-CONTEXT
        // "Deferred Ideas — Configurable session_window_days".
        let codexSessionWindowDays = defaults.codex.sessionWindowDays

        // --- Plan 03-08 — gemini section (env > toml > defaults) ---

        // gemini.enabled: TOML only (no env override).
        let geminiEnabled: Bool
        if case .bool(let b) = geminiSection["enabled"] {
            geminiEnabled = b
        } else {
            geminiEnabled = defaults.gemini.enabled
        }

        // gemini.projectIDOverride: env GEMINI_PROJECT_ID ONLY. NOT
        // credential material — exposed as plain String?.
        let geminiProjectID: String?
        if let envProject = env.value(forKey: "GEMINI_PROJECT_ID") {
            geminiProjectID = envProject
        } else {
            geminiProjectID = nil
        }

        return AppConfig(
            refreshInterval: refreshInterval,
            threshold: threshold,
            openrouter: OpenRouterConfig(
                apiKey: apiKey,
                apiURL: apiURL,
                httpReferer: httpReferer,
                xTitle: xTitle,
                enabled: enabled
            ),
            codex: CodexConfig(
                enabled: codexEnabled,
                bearerOverride: codexBearer,
                sessionWindowDays: codexSessionWindowDays
            ),
            gemini: GeminiConfig(
                enabled: geminiEnabled,
                projectIDOverride: geminiProjectID
            )
        )
    }

    /// Convenience accessor for the resolved OpenRouter bearer secret.
    ///
    /// Returns `nil` when neither env nor TOML supplies a key.
    /// Plan 01.05 composition root and Plan 01.04 provider construction use this.
    public var openRouterKey: Secret? {
        load().openrouter.apiKey
    }
}

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
/// SEC-03 (Phase 6 / Plan 06-01 — implemented here):
///   - `ensureConfigFile(contents:)` creates the file at POSIX mode `0o600` when absent
///     (owner read/write only). Idempotent: existing files are NOT overwritten or rechmod'd.
///   - `checkAndWarnPermissions()` is wired into the tail of every `load()` call and warns
///     (via `os.Logger`, never crashes) when the existing file is world- or group-readable
///     (`mode & 0o077 != 0`). Phase 1 read-only semantics of `load()` are preserved — it does
///     NOT call `ensureConfigFile`; the file is created only on explicit caller request.
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
    /// SEC-03: calls `checkAndWarnPermissions()` at the tail so a world/group-readable
    /// `config.toml` surfaces a warning on every load (never crashes).
    public func load() -> AppConfig {
        // SEC-03: surface a wide-permission config on every load. Cheap stat() —
        // runs at the tail so a missing/unreadable file does not block parsing.
        defer { checkAndWarnPermissions() }

        // 1. Read TOML file (nil if absent or unreadable — fail-soft)
        let tomlText = try? String(contentsOf: tomlPath, encoding: .utf8)
        let toml = tomlText.map { TomlReader.parse($0, logger: logger) } ?? [:]

        let topLevel = toml[""] ?? [:]
        let orSection = toml["openrouter"] ?? [:]
        // Plan 03-08 — new per-provider sections.
        let codexSection = toml["codex"] ?? [:]
        let geminiSection = toml["gemini"] ?? [:]
        // Plan 04-02 — local runtime sections (no env override — port + enable are config knobs).
        let ollamaSection = toml["ollama"] ?? [:]
        let lmstudioSection = toml["lmstudio"] ?? [:]
        let llamacppSection = toml["llamacpp"] ?? [:]

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

        // --- Plan 04-02 — ollama section (toml > defaults; NO env override per CONTEXT Discretion) ---

        // ollama.enabled: TOML only.
        let ollamaEnabled: Bool
        if case .bool(let b) = ollamaSection["enabled"] {
            ollamaEnabled = b
        } else {
            ollamaEnabled = defaults.ollama.enabled
        }

        // --- Plan 04-02 — lmstudio section (toml > defaults; NO env override) ---

        // lmstudio.enabled: TOML only.
        let lmstudioEnabled: Bool
        if case .bool(let b) = lmstudioSection["enabled"] {
            lmstudioEnabled = b
        } else {
            lmstudioEnabled = defaults.lmstudio.enabled
        }

        // lmstudio.port: TOML only; falls back to default 1234 when absent or unparseable.
        let lmstudioPort: Int
        if case .int(let i) = lmstudioSection["port"] {
            lmstudioPort = i
        } else {
            lmstudioPort = defaults.lmstudio.port
        }

        // --- Plan 04-02 — llamacpp section (toml > nil; NO env override; NO default port) ---

        // llamacpp.enabled: TOML only.
        let llamacppEnabled: Bool
        if case .bool(let b) = llamacppSection["enabled"] {
            llamacppEnabled = b
        } else {
            llamacppEnabled = defaults.llamacpp.enabled
        }

        // llamacpp.port: REQUIRED in TOML (LOCAL-03 no scanning). Absent → nil → Plan 04-08
        // seeds the D-04 discoverability placeholder instead of registering a live actor.
        // Garbage value (e.g. string instead of int) silently falls to nil per D-18 fail-soft.
        let llamacppPort: Int?
        if case .int(let i) = llamacppSection["port"] {
            llamacppPort = i
        } else {
            llamacppPort = nil
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
            ),
            ollama: OllamaConfig(enabled: ollamaEnabled),
            lmstudio: LMStudioConfig(enabled: lmstudioEnabled, port: lmstudioPort),
            llamacpp: LlamaCppConfig(enabled: llamacppEnabled, port: llamacppPort)
        )
    }

    /// Loads configuration applying `userDefaults > env > toml > defaults` precedence for knobs.
    ///
    /// Credentials (apiKey, bearer, OAuth paths) always follow `env > toml` only (D-03).
    /// Only user-mutable knobs are overlaid from `preferences`:
    /// - `refreshInterval` — polling cadence
    /// - `threshold` — warning-band fraction
    /// - per-provider `enabled` — when explicitly set in UserDefaults (non-empty map)
    ///
    /// NOTE: `theme` and `openAtLogin` are UI-only preferences — they do NOT appear in
    /// `AppConfig` and are consumed directly from `UserPreferencesStore` by the UI layer.
    ///
    /// - Parameter preferences: The `UserPreferencesStore` to overlay. When `nil`,
    ///   returns the same result as `load()` (back-compat).
    @MainActor
    public func load(preferences: UserPreferencesStore? = nil) -> AppConfig {
        var config = load()   // existing env > toml > defaults chain

        guard let prefs = preferences else { return config }

        // D-02: UserDefaults wins for user-mutable knobs.
        // Always apply — on a fresh install both sides default to the same value, so
        // a no-op override is harmless.
        config = AppConfig(
            refreshInterval: prefs.refreshInterval,
            threshold: prefs.threshold,
            openrouter: config.openrouter.withEnabled(
                prefs.providerEnabled[.openrouter] ?? config.openrouter.enabled
            ),
            codex: config.codex.withEnabled(
                prefs.providerEnabled[.codex] ?? config.codex.enabled
            ),
            gemini: config.gemini.withEnabled(
                prefs.providerEnabled[.gemini] ?? config.gemini.enabled
            ),
            ollama: config.ollama.withEnabled(
                prefs.providerEnabled[.ollama] ?? config.ollama.enabled
            ),
            lmstudio: config.lmstudio.withEnabled(
                prefs.providerEnabled[.lmstudio] ?? config.lmstudio.enabled
            ),
            llamacpp: config.llamacpp.withEnabled(
                prefs.providerEnabled[.llamacpp] ?? config.llamacpp.enabled
            )
        )
        // NOTE: apiKey, bearer, OAuth credentials are NOT touched here (D-03, CFG-01).
        return config
    }

    /// Convenience accessor for the resolved OpenRouter bearer secret.
    ///
    /// Returns `nil` when neither env nor TOML supplies a key.
    /// Plan 01.05 composition root and Plan 01.04 provider construction use this.
    public var openRouterKey: Secret? {
        load().openrouter.apiKey
    }
}

// MARK: - SEC-03 / Plan 06-01 — config.toml permission hardening

extension ConfigStore {

    /// Pure predicate that mirrors the production warning gate.
    ///
    /// Returns `true` when any group or other permission bit is set
    /// (`mode & 0o077 != 0`) — i.e. the file is at least partially readable,
    /// writable, or executable by users other than the owner.
    ///
    /// Exposed `static` so unit tests can assert the gate against canonical
    /// modes without relying on a log sink (mirrors Phase 1 STATE #33
    /// pure-function test seam pattern).
    public static func isWorldOrGroupReadable(mode: Int) -> Bool {
        (mode & 0o077) != 0
    }

    /// Creates `config.toml` at `tomlPath` with POSIX mode `0o600` when absent.
    ///
    /// Idempotent: if the file already exists this method is a no-op — it does
    /// NOT overwrite contents and does NOT modify permissions (a user who has
    /// deliberately widened access for a non-secret-bearing config keeps their
    /// choice; the world-readable warning in `load()` surfaces the risk).
    ///
    /// Creates the parent directory (`~/.config/agents-usage-bar/`) with
    /// intermediate directories when missing.
    ///
    /// SEC-03: sets `0o600` both via `createFile(attributes:)` and a
    /// follow-up `setAttributes(...)` (belt-and-suspenders — `createFile`
    /// silently ignores `attributes` on some filesystems).
    ///
    /// - Parameter contents: Bytes to write into the newly created file.
    /// - Throws: Filesystem errors from `createDirectory` or `setAttributes`.
    ///   `createFile` returns a Bool on failure rather than throwing — when it
    ///   reports `false` we throw a `CocoaError(.fileWriteUnknown)` so callers
    ///   can react.
    public func ensureConfigFile(contents: Data) throws {
        // Idempotent: existing file is left intact (contents AND mode).
        guard !FileManager.default.fileExists(atPath: tomlPath.path) else { return }

        let parent = tomlPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        let created = FileManager.default.createFile(
            atPath: tomlPath.path,
            contents: contents,
            attributes: attributes
        )
        guard created else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Belt-and-suspenders: re-apply 0o600 — `createFile` is documented to
        // silently ignore the attributes dictionary on some filesystems.
        try FileManager.default.setAttributes(attributes, ofItemAtPath: tomlPath.path)
    }

    /// Inspects `config.toml`'s POSIX permissions and warns via `os.Logger`
    /// when the file is world- or group-readable.
    ///
    /// Silent no-op when the file does not exist or its `posixPermissions`
    /// attribute is unavailable — SEC-03 explicitly requires "never crashes".
    ///
    /// The warning interpolates only the path and octal mode (`privacy: .public`
    /// — neither is a secret) and surfaces a `chmod 0600 <path>` remediation.
    /// File contents are NEVER logged (T-06-02 mitigation).
    public func checkAndWarnPermissions() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tomlPath.path),
              let modeRaw = attrs[.posixPermissions] as? Int
        else { return }

        let mode = modeRaw & 0o777
        guard ConfigStore.isWorldOrGroupReadable(mode: mode) else { return }

        let modeOctal = String(mode, radix: 8)
        logger.warning(
            "config.toml at \(self.tomlPath.path, privacy: .public) has permissions \(modeOctal, privacy: .public) — expected 0600. Other local users may read your API keys. Remediate: chmod 0600 \(self.tomlPath.path, privacy: .public)"
        )
    }
}

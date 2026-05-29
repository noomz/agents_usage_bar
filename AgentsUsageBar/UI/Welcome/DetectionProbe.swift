import Foundation

// MARK: - DetectionResult

/// Detection result for a single provider.
///
/// Used by `DetectionProbe.probeAll` to communicate whether a provider's
/// required configuration or runtime presence was found.
///
/// - Note: CFG-06 anti-feature enforced: NEVER reads shell RC files.
///   Detection uses only:
///   - Env vars / TOML values already loaded into `AppConfig`
///   - Credential/settings files under `~/.claude/`, `~/.codex/`, `~/.gemini/`
///   - HTTP probes on localhost (Ollama, LM Studio, llama.cpp)
public enum DetectionResult: Sendable, Equatable {
    /// Signal found — provider will be auto-enabled on first launch (D-11).
    case detected
    /// HTTP probe reached the host but the service is not responding correctly
    /// (localhost providers only: Ollama, LM Studio, llama.cpp).
    case notRunning
    /// Required configuration (e.g. port, API key) is absent.
    /// Used for: OpenRouter (no key), llama.cpp (no port configured).
    case notConfigured
    /// FS probes found no credential or settings files.
    /// Used for: Claude, Codex, Gemini.
    case notDetected
}

// MARK: - DetectionProbe

/// Runs per-provider detection probes in parallel via `withTaskGroup`.
///
/// - FS-based probes (synchronous): OpenRouter (config key), Claude, Codex, Gemini
///   (credential files).
/// - HTTP-based probes (async, 2s timeout): Ollama, LM Studio, llama.cpp
///   (localhost endpoints via `localhostHTTP`).
///
/// CFG-06 compliance: NEVER reads shell RC files. All detection signals come
/// from `AppConfig` (env/TOML already parsed at launch) or specific credential
/// file paths.
///
/// D-12: All 7 probes run concurrently. Wall-clock time ≤ 2s (HTTP timeout is
/// 2s on `localhostHTTP`; FS probes are negligible).
public enum DetectionProbe {

    // MARK: - Public API

    /// Runs all 7 provider detection probes concurrently.
    ///
    /// - Parameters:
    ///   - config: Current `AppConfig` — used for env/TOML values (apiKey, ports).
    ///   - localhostHTTP: The 2s-timeout `HTTPClient` from `AppDependencies`.
    ///     Pass the existing instance — do NOT create a new `URLSession`.
    ///   - fileManager: Injectable for test isolation. Defaults to `.default`.
    /// - Returns: Map of provider → detection result for all 7 providers.
    public static func probeAll(
        config: AppConfig,
        localhostHTTP: any HTTPClient,
        fileManager: FileManager = .default
    ) async -> [ProviderID: DetectionResult] {
        // Pre-compute all synchronous FS probes BEFORE entering the task group.
        // FileManager is not Sendable under Swift 6 strict concurrency, so it cannot
        // be captured in `sending` task-group closures. Pre-computing the results
        // (which ARE Sendable — DetectionResult is Sendable) is the correct pattern.
        let openrouterResult: DetectionResult = config.openrouter.apiKey != nil ? .detected : .notConfigured
        let claudeResult: DetectionResult = ClaudeCredentialLoader().loadCredentials() != nil
            ? .detected
            : probeClaudeFS(fileManager: fileManager)
        let codexResult = probeCodexFS(fileManager: fileManager)
        let geminiResult = probeGeminiFS(fileManager: fileManager)

        // Per-provider port/URL values (Sendable: Int, URL, Optional<Int>)
        let lmstudioPort = config.lmstudio.port
        let llamacppPort = config.llamacpp.port

        return await withTaskGroup(of: (ProviderID, DetectionResult).self) { group in

            // 1. OpenRouter — pre-computed synchronous result
            group.addTask { (.openrouter, openrouterResult) }

            // 2. Claude — pre-computed synchronous result
            group.addTask { (.claude, claudeResult) }

            // 3. Codex — pre-computed synchronous result
            group.addTask { (.codex, codexResult) }

            // 4. Gemini — pre-computed synchronous result
            group.addTask { (.gemini, geminiResult) }

            // 5. Ollama — HTTP probe (2s timeout via localhostHTTP)
            group.addTask {
                let url = URL(string: "http://localhost:11434/api/version")!
                let result = await probeLocalHTTP(url: url, http: localhostHTTP)
                return (.ollama, result)
            }

            // 6. LM Studio — HTTP probe on configured port (default 1234)
            group.addTask {
                let url = URL(string: "http://localhost:\(lmstudioPort)/v1/models")!
                let result = await probeLocalHTTP(url: url, http: localhostHTTP)
                return (.lmstudio, result)
            }

            // 7. llama.cpp — requires configured port (LOCAL-03: no port scanning)
            group.addTask {
                guard let port = llamacppPort else {
                    return (.llamacpp, .notConfigured)
                }
                let url = URL(string: "http://localhost:\(port)/health")!
                let result = await probeLocalHTTP(url: url, http: localhostHTTP)
                return (.llamacpp, result)
            }

            var results: [ProviderID: DetectionResult] = [:]
            for await (id, result) in group {
                results[id] = result
            }
            return results
        }
    }

    // MARK: - FS probe helpers (synchronous)
    //
    // CFG-06: None of these helpers read shell RC files.
    // All reads are limited to ~/.claude/, ~/.codex/, ~/.gemini/ paths.

    private static func probeClaudeFS(fileManager: FileManager) -> DetectionResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        // Check ~/.claude/projects/ dir (transcript files) and ~/.claude/.credentials.json
        let projectsPath = home + "/.claude/projects"
        let credPath = home + "/.claude/.credentials.json"
        if fileManager.fileExists(atPath: projectsPath) ||
           fileManager.fileExists(atPath: credPath) {
            return .detected
        }
        return .notDetected
    }

    private static func probeCodexFS(fileManager: FileManager) -> DetectionResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        // Check ~/.codex/sessions/ (rollout files) or ~/.codex/auth.json
        let sessionsPath = home + "/.codex/sessions"
        let authPath = home + "/.codex/auth.json"
        if fileManager.fileExists(atPath: sessionsPath) ||
           fileManager.fileExists(atPath: authPath) {
            return .detected
        }
        return .notDetected
    }

    private static func probeGeminiFS(fileManager: FileManager) -> DetectionResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        // Gemini requires BOTH the OAuth credentials file AND the settings gate
        let credsPath = home + "/.gemini/oauth_creds.json"
        let settingsPath = home + "/.gemini/settings.json"
        guard fileManager.fileExists(atPath: credsPath) else { return .notDetected }
        // GeminiSettingsGate checks security.auth.selectedType == "oauth-personal"
        // (RESEARCH correction #2: nested keypath, not flat)
        guard GeminiSettingsGate.isOAuthPersonal(
            settingsPath: URL(fileURLWithPath: settingsPath),
            fileManager: fileManager
        ) else { return .notDetected }
        return .detected
    }

    // MARK: - HTTP probe helper (async)

    /// Probes a localhost HTTP endpoint. Returns `.detected` on 2xx, `.notRunning` on
    /// any connection failure (the 2s timeout is enforced by the `localhostHTTP` client).
    private static func probeLocalHTTP(url: URL, http: any HTTPClient) async -> DetectionResult {
        struct EmptyResponse: Decodable, Sendable {}
        do {
            _ = try await http.get(
                url,
                bearer: Optional<Secret>.none,
                extraHeaders: [:],
                as: EmptyResponse.self
            )
            return .detected
        } catch {
            // All localhost connection failures → .notRunning
            // (connection refused, timeout, host not found — all are "not running" for detection)
            return .notRunning
        }
    }
}

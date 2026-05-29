import Testing
@testable import AgentsUsageBar
import Foundation

// MARK: - AppConfigCodexGeminiTests (Plan 03-08 Task 1)
//
// Plan 03-08 — verifies the CodexConfig + GeminiConfig structs and their
// defaults inside `AppConfig.defaults`, plus the Secret-wrapping invariant
// for the optional `CODEX_BEARER_TOKEN` override.
//
// Sibling suite `ConfigStoreCodexGeminiTests` covers the env > toml >
// defaults precedence rules (D-17) for the new [codex] / [gemini] sections.

@Suite("AppConfigCodexGeminiTests")
struct AppConfigCodexGeminiTests {

    // MARK: - Defaults (Test 1 & 2)

    @Test("AppConfig.defaults.codex has enabled=true, sessionWindowDays=2, no bearer override")
    func defaults_codex() {
        let c = AppConfig.defaults.codex
        #expect(c.enabled == true)
        #expect(c.sessionWindowDays == 2)
        #expect(c.bearerOverride == nil)
    }

    @Test("AppConfig.defaults.gemini has enabled=true, no projectID override")
    func defaults_gemini() {
        let g = AppConfig.defaults.gemini
        #expect(g.enabled == true)
        #expect(g.projectIDOverride == nil)
    }

    // MARK: - Equatable separation (Test 3)

    @Test("AppConfig with both providers disabled is Equatable-different from defaults")
    func disabledConfig_isNotEquatableToDefaults() {
        let disabled = AppConfig(
            refreshInterval: AppConfig.defaults.refreshInterval,
            threshold: AppConfig.defaults.threshold,
            openrouter: AppConfig.defaults.openrouter,
            codex: CodexConfig(enabled: false, bearerOverride: nil, sessionWindowDays: 2),
            gemini: GeminiConfig(enabled: false, projectIDOverride: nil),
            ollama: AppConfig.defaults.ollama,
            lmstudio: AppConfig.defaults.lmstudio,
            llamacpp: AppConfig.defaults.llamacpp
        )
        #expect(disabled != AppConfig.defaults)
        #expect(disabled.codex.enabled == false)
        #expect(disabled.gemini.enabled == false)
    }

    // MARK: - Secret wrapping (Test 4)

    @Test("CodexConfig with Secret bearerOverride redacts in description")
    func codex_bearerOverride_redacted() {
        let c = CodexConfig(
            enabled: true,
            bearerOverride: Secret("fake-bearer"),
            sessionWindowDays: 2
        )
        // Secret.description always returns "<redacted>" — SEC-01.
        #expect(c.bearerOverride?.description == "<redacted>")
        // The reveal accessor produces the underlying string (sanity).
        #expect(c.bearerOverride?.revealForRequest() == "fake-bearer")
    }

    @Test("AppConfig.defaults survives equality round-trip via fresh construction")
    func appConfigDefaults_equality() {
        let a = AppConfig.defaults
        let b = AppConfig(
            refreshInterval: .m5,
            threshold: 0.80,
            openrouter: OpenRouterConfig(
                apiKey: nil,
                apiURL: URL(string: "https://openrouter.ai/api/v1")!,
                httpReferer: nil,
                xTitle: "Agents Usage Bar",
                enabled: true
            ),
            codex: CodexConfig(enabled: true, bearerOverride: nil, sessionWindowDays: 2),
            gemini: GeminiConfig(enabled: true, projectIDOverride: nil),
            ollama: OllamaConfig(enabled: true),
            lmstudio: LMStudioConfig(enabled: true, port: 1234),
            llamacpp: LlamaCppConfig(enabled: true, port: nil)
        )
        #expect(a == b)
    }
}

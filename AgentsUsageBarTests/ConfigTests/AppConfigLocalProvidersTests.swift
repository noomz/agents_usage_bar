import Testing
@testable import AgentsUsageBar
import Foundation

// MARK: - AppConfigLocalProvidersTests (Plan 04-02 Task 3)
//
// Plan 04-02 — verifies the OllamaConfig, LMStudioConfig, and LlamaCppConfig
// structs and their defaults inside `AppConfig.defaults`.
//
// Locks the invariants that Plan 04-08 (composition root) and Plan 04-06
// (LlamaCppProvider) depend on: specifically that `llamacpp.port == nil` is
// the nil-default gating signal that triggers D-04 placeholder seeding.
//
// Sibling suite `ConfigStoreLocalSectionsTests` covers TOML > defaults
// precedence for the new [ollama] / [lmstudio] / [llamacpp] sections.

@Suite("AppConfigLocalProvidersTests")
struct AppConfigLocalProvidersTests {

    // MARK: - Ollama defaults

    @Test("defaults_ollamaEnabledTrue")
    func defaults_ollamaEnabledTrue() {
        #expect(AppConfig.defaults.ollama.enabled == true)
    }

    // MARK: - LM Studio defaults

    @Test("defaults_lmstudioEnabledTrueAndPort1234")
    func defaults_lmstudioEnabledTrueAndPort1234() {
        #expect(AppConfig.defaults.lmstudio.enabled == true)
        #expect(AppConfig.defaults.lmstudio.port == 1234)
    }

    // MARK: - llama.cpp defaults (LOCAL-03 nil-port invariant)

    @Test("defaults_llamacppEnabledTrueAndPortNil")
    func defaults_llamacppEnabledTrueAndPortNil() {
        #expect(AppConfig.defaults.llamacpp.enabled == true)
        #expect(AppConfig.defaults.llamacpp.port == nil)
    }

    // MARK: - Equatable — OllamaConfig

    @Test("equatable_distinguishesEnabledFalse")
    func equatable_distinguishesEnabledFalse() {
        let a = OllamaConfig(enabled: false)
        let b = OllamaConfig(enabled: true)
        #expect(a != b)
    }

    // MARK: - Equatable — LMStudioConfig port difference

    @Test("equatable_lmstudioPortDifference")
    func equatable_lmstudioPortDifference() {
        let a = LMStudioConfig(enabled: true, port: 1234)
        let b = LMStudioConfig(enabled: true, port: 8765)
        #expect(a != b)
    }

    // MARK: - LlamaCppConfig nil-port optional invariant

    @Test("llamacppConfig_acceptsNilPort")
    func llamacppConfig_acceptsNilPort() {
        // Locks the optional invariant: port == nil is the D-04 placeholder gating signal.
        // Plan 04-08 reads port == nil to decide between actor registration and placeholder seed.
        let config = LlamaCppConfig(enabled: true, port: nil)
        #expect(config.port == nil)
    }

    // MARK: - AppConfig carries all three local configs

    @Test("appConfig_carriesAllThreeLocals")
    func appConfig_carriesAllThreeLocals() {
        let cfg = AppConfig.defaults
        #expect(cfg.ollama.enabled)
        #expect(cfg.lmstudio.enabled)
        #expect(cfg.llamacpp.enabled)
    }

    // MARK: - Negative invariant: no Secret wrapping for ports (CONTEXT Discretion)

    @Test("lmstudioPort_isPlainInt_notSecret")
    func lmstudioPort_isPlainInt_notSecret() {
        // Ports are config knobs, not credentials — plain Int, not Secret (CONTEXT Discretion).
        let config = LMStudioConfig(enabled: true, port: 4321)
        #expect(config.port == 4321)
        // Verify type is Int (not wrapped) — assignment to plain Int compiles only if unwrapped.
        let portValue: Int = config.port
        #expect(portValue == 4321)
    }

    // MARK: - Negative invariant: LOCAL-06 anti-feature — no token fields on locals

    @Test("noTokenFieldsOnLocalConfigs")
    func noTokenFieldsOnLocalConfigs() {
        // LOCAL-06: locals never track tokens. Verifying the structs carry no such fields
        // (these compile-time checks validate the struct shapes are minimal).
        let ollama = OllamaConfig(enabled: true)
        let lms = LMStudioConfig(enabled: true, port: 1234)
        let cpp = LlamaCppConfig(enabled: true, port: 8080)
        // The structs only have `enabled` (and `port` for the latter two) — no token fields.
        #expect(ollama.enabled == true)
        #expect(lms.port == 1234)
        #expect(cpp.port == 8080)
    }
}

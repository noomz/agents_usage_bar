import Testing
@testable import AgentsUsageBar
import Foundation

// MARK: - ConfigStoreLocalSectionsTests (Plan 04-02 Task 3)
//
// Plan 04-02 — verifies toml > defaults precedence for the new [ollama],
// [lmstudio], and [llamacpp] TOML sections (CONTEXT Discretion §"TOML schema
// additions"). No env override paths exist for local configs — they are config
// knobs (port + enable), not secrets.
//
// Negative invariant: no OLLAMA_* / LMSTUDIO_* / LLAMACPP_* env reads.
//
// Mirrors helper patterns from ConfigStoreCodexGeminiTests (Plan 03-08).
// Each test uses DictionaryEnvReader([:]) — never ProcessInfoEnvReader.

@Suite("ConfigStoreLocalSectionsTests")
struct ConfigStoreLocalSectionsTests {

    // MARK: - Helpers

    private func writeTempToml(_ content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStoreLocalSectionsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.toml")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func nonExistentURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStoreLocalSectionsTests-nonexistent-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
    }

    // MARK: - Test 1: Empty TOML → defaults for all three locals

    @Test("emptyToml_yieldsDefaults")
    func emptyToml_yieldsDefaults() {
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: nonExistentURL())
        let config = store.load()
        // Ollama defaults
        #expect(config.ollama.enabled == true)
        // LM Studio defaults
        #expect(config.lmstudio.enabled == true)
        #expect(config.lmstudio.port == 1234)
        // llama.cpp defaults — port MUST be nil when absent (LOCAL-03 no scanning)
        #expect(config.llamacpp.enabled == true)
        #expect(config.llamacpp.port == nil)
    }

    // MARK: - Test 2: [ollama] enabled = false disables Ollama

    @Test("ollamaSectionDisablesOllama")
    func ollamaSectionDisablesOllama() throws {
        let tomlURL = try writeTempToml("[ollama]\nenabled = false\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let config = store.load()
        #expect(config.ollama.enabled == false)
        // Other locals unaffected
        #expect(config.lmstudio.enabled == true)
        #expect(config.llamacpp.enabled == true)
    }

    // MARK: - Test 3: [lmstudio] port override is read

    @Test("lmstudioPortOverrideRead")
    func lmstudioPortOverrideRead() throws {
        let tomlURL = try writeTempToml("[lmstudio]\nport = 8765\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let config = store.load()
        #expect(config.lmstudio.port == 8765)
        // enabled still defaults true
        #expect(config.lmstudio.enabled == true)
    }

    // MARK: - Test 4: [llamacpp] port present activates the row

    @Test("llamacppPortPresentEnablesRow")
    func llamacppPortPresentEnablesRow() throws {
        // Plan 04-08 gates actor registration on port != nil.
        let tomlURL = try writeTempToml("[llamacpp]\nport = 8080\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let config = store.load()
        #expect(config.llamacpp.port == 8080)
        #expect(config.llamacpp.enabled == true)
    }

    // MARK: - Test 5: [llamacpp] enabled = false with port still carries both

    @Test("llamacppEnabledFalseDisablesEvenWithPort")
    func llamacppEnabledFalseDisablesEvenWithPort() throws {
        // Plan 04-08 enforces the AND-gate: enabled && port != nil.
        let tomlURL = try writeTempToml("[llamacpp]\nenabled = false\nport = 8080\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let config = store.load()
        #expect(config.llamacpp.enabled == false)
        #expect(config.llamacpp.port == 8080)
    }

    // MARK: - Test 6: Garbage TOML value falls back to default (D-18 fail-soft)

    @Test("garbageValueFallsBackToDefault")
    func garbageValueFallsBackToDefault() throws {
        // [lmstudio] port = "not-a-number" is a string, not int.
        // TomlReader silently drops the bad line (D-18). Port falls back to default 1234.
        let tomlURL = try writeTempToml("[lmstudio]\nport = \"not-a-number\"\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let config = store.load()
        #expect(config.lmstudio.port == 1234)
    }

    // MARK: - Test 7: Env OLLAMA_*/LMSTUDIO_*/LLAMACPP_* env vars are ignored (no env knobs)

    @Test("noEnvOverride_forLocals")
    func noEnvOverride_forLocals() throws {
        // Negative test: env vars with these names must NOT affect config.
        // CONTEXT Discretion §"TOML schema additions": no env override for locals.
        let store = ConfigStore(
            env: DictionaryEnvReader([
                "OLLAMA_API_URL": "http://example.com",
                "LMSTUDIO_PORT": "9999",
                "LLAMACPP_PORT": "7777"
            ]),
            tomlPath: nonExistentURL()
        )
        let config = store.load()
        // All values must equal defaults — env is completely ignored for locals.
        #expect(config.ollama.enabled == true)
        #expect(config.lmstudio.port == 1234)
        #expect(config.llamacpp.port == nil)
    }

    // MARK: - Test 8: Phase 1/2/3 surfaces unchanged when Phase 4 sections added

    @Test("regression_phase3OpenRouterCodexGeminiUnchanged")
    func regression_phase3OpenRouterCodexGeminiUnchanged() throws {
        // Load a fixture that exercises Phase 1 + Phase 3 + Phase 4 sections.
        // Assert Phase 1/2/3 surfaces match pre-Phase-4 expectations byte-for-byte.
        let toml = """
            [openrouter]
            api_key = "sk-or-v1-test"

            [codex]
            enabled = false

            [gemini]
            enabled = true

            [ollama]
            enabled = false

            [lmstudio]
            port = 5678

            [llamacpp]
            enabled = true
            port = 9090
            """
        let tomlURL = try writeTempToml(toml)
        let store = ConfigStore(
            env: DictionaryEnvReader([:]),
            tomlPath: tomlURL
        )
        let config = store.load()

        // Phase 1 — OpenRouter
        #expect(config.openrouter.apiKey?.revealForRequest() == "sk-or-v1-test")
        // Phase 3 — Codex disabled, Gemini enabled
        #expect(config.codex.enabled == false)
        #expect(config.gemini.enabled == true)
        // Phase 4 — new local sections parsed correctly
        #expect(config.ollama.enabled == false)
        #expect(config.lmstudio.port == 5678)
        #expect(config.llamacpp.enabled == true)
        #expect(config.llamacpp.port == 9090)
    }
}

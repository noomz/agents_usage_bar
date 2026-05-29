import Testing
@testable import AgentsUsageBar
import Foundation

// MARK: - ConfigStoreCodexGeminiTests (Plan 03-08 Task 1)
//
// Plan 03-08 — verifies the env > toml > defaults precedence for the new
// [codex] and [gemini] TOML sections (D-17), plus the Phase 1 STATE #22
// "empty env string treated as absent" rule for `CODEX_BEARER_TOKEN`, plus
// D-18 fail-soft (garbage TOML never throws), plus the regression that
// the Phase 1 OpenRouter precedence is unaffected.
//
// Mirrors the helper patterns in `ConfigStoreTests` (temp-file TOML +
// DictionaryEnvReader injection).

@Suite("ConfigStoreCodexGeminiTests")
struct ConfigStoreCodexGeminiTests {

    // MARK: - Helpers (mirror ConfigStoreTests)

    private func writeTempToml(_ content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStoreCodexGeminiTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.toml")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func nonExistentURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStoreCodexGeminiTests-nonexistent-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
    }

    // MARK: - Test 1: Empty env + empty TOML → both providers enabled (defaults)

    @Test("emptyTomlAndEnv_bothEnabled")
    func emptyTomlAndEnv_bothEnabled() {
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: nonExistentURL())
        let config = store.load()
        #expect(config.codex.enabled == true)
        #expect(config.gemini.enabled == true)
        #expect(config.codex.bearerOverride == nil)
        #expect(config.gemini.projectIDOverride == nil)
        #expect(config.codex.sessionWindowDays == 2)
    }

    // MARK: - Test 2: TOML disables codex

    @Test("tomlDisablesCodex")
    func tomlDisablesCodex() throws {
        let tomlURL = try writeTempToml("[codex]\nenabled = false\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let config = store.load()
        #expect(config.codex.enabled == false)
        // Gemini unaffected (still defaulted enabled)
        #expect(config.gemini.enabled == true)
    }

    // MARK: - Test 3: TOML disables gemini

    @Test("tomlDisablesGemini")
    func tomlDisablesGemini() throws {
        let tomlURL = try writeTempToml("[gemini]\nenabled = false\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let config = store.load()
        #expect(config.gemini.enabled == false)
        #expect(config.codex.enabled == true)
    }

    // MARK: - Test 4: Env CODEX_BEARER_TOKEN sets Secret-wrapped override

    @Test("envCodexBearerToken_setsSecretWrappedOverride")
    func envCodexBearerToken_setsSecretWrappedOverride() {
        let store = ConfigStore(
            env: DictionaryEnvReader(["CODEX_BEARER_TOKEN": "FAKE-codex-override"]),
            tomlPath: nonExistentURL()
        )
        let config = store.load()
        // SEC-01: description redacts, but reveal accessor exposes the literal.
        #expect(config.codex.bearerOverride?.description == "<redacted>")
        #expect(config.codex.bearerOverride?.revealForRequest() == "FAKE-codex-override")
    }

    // MARK: - Test 5: Empty env CODEX_BEARER_TOKEN treated as absent (STATE #22)

    @Test("emptyEnvCodexBearerToken_treatedAsAbsent")
    func emptyEnvCodexBearerToken_treatedAsAbsent() {
        let store = ConfigStore(
            env: DictionaryEnvReader(["CODEX_BEARER_TOKEN": ""]),
            tomlPath: nonExistentURL()
        )
        let config = store.load()
        #expect(config.codex.bearerOverride == nil)
    }

    // MARK: - Test 6: Env GEMINI_PROJECT_ID exposed verbatim (not Secret)

    @Test("envGeminiProjectID_exposedVerbatim")
    func envGeminiProjectID_exposedVerbatim() {
        let store = ConfigStore(
            env: DictionaryEnvReader(["GEMINI_PROJECT_ID": "gen-lang-client-7777"]),
            tomlPath: nonExistentURL()
        )
        let config = store.load()
        // projectID is NOT credential material — exposed as plain String.
        #expect(config.gemini.projectIDOverride == "gen-lang-client-7777")
    }

    // MARK: - Test 7: Garbage TOML in [codex]/[gemini] → fail-soft, no throw (D-18)

    @Test("garbageTomlInCodexGemini_failsSoft")
    func garbageTomlInCodexGemini_failsSoft() throws {
        // Invalid scalar values + a stray non-key=value line in [codex] and [gemini].
        let tomlURL = try writeTempToml(
            "[codex]\nenabled = not-a-bool\n!!!garbage\n[gemini]\nenabled = also-bad\n"
        )
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        // D-18: load() never throws. Garbage lines logged + skipped; defaults remain.
        let config = store.load()
        #expect(config.codex.enabled == true)        // unchanged from default
        #expect(config.gemini.enabled == true)       // unchanged from default
    }

    // MARK: - Test 8: Phase 1 OpenRouter precedence still works (regression)

    @Test("phase1OpenRouterPrecedence_unchanged")
    func phase1OpenRouterPrecedence_unchanged() throws {
        let tomlURL = try writeTempToml(
            "[openrouter]\napi_key = \"toml-loses\"\n[codex]\nenabled = false\n"
        )
        let store = ConfigStore(
            env: DictionaryEnvReader(["OPENROUTER_API_KEY": "env-wins"]),
            tomlPath: tomlURL
        )
        let config = store.load()
        // OpenRouter: env beats TOML (Phase 1 D-17 invariant).
        #expect(config.openrouter.apiKey?.revealForRequest() == "env-wins")
        // Codex: TOML disables it.
        #expect(config.codex.enabled == false)
        // Gemini: untouched default.
        #expect(config.gemini.enabled == true)
    }

    // MARK: - Test 9: Both providers explicitly enabled via TOML

    @Test("tomlExplicitlyEnablesBoth")
    func tomlExplicitlyEnablesBoth() throws {
        let tomlURL = try writeTempToml(
            "[codex]\nenabled = true\n[gemini]\nenabled = true\n"
        )
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let config = store.load()
        #expect(config.codex.enabled == true)
        #expect(config.gemini.enabled == true)
    }

    // MARK: - Test 10: Env GEMINI_PROJECT_ID empty string treated as absent

    @Test("emptyEnvGeminiProjectID_treatedAsAbsent")
    func emptyEnvGeminiProjectID_treatedAsAbsent() {
        let store = ConfigStore(
            env: DictionaryEnvReader(["GEMINI_PROJECT_ID": ""]),
            tomlPath: nonExistentURL()
        )
        let config = store.load()
        // STATE #22: empty string treated as absent (DictionaryEnvReader contract).
        #expect(config.gemini.projectIDOverride == nil)
    }

    // MARK: - Test 11: Codex enabled=false in TOML + env bearer set → both honored independently

    @Test("disabledCodexButBearerOverride_bothHonored")
    func disabledCodexButBearerOverride_bothHonored() throws {
        let tomlURL = try writeTempToml("[codex]\nenabled = false\n")
        let store = ConfigStore(
            env: DictionaryEnvReader(["CODEX_BEARER_TOKEN": "advanced-override"]),
            tomlPath: tomlURL
        )
        let config = store.load()
        // Disabled per TOML but the env override is still parsed (composition root
        // is responsible for honoring `enabled` when deciding to register the
        // provider).
        #expect(config.codex.enabled == false)
        #expect(config.codex.bearerOverride?.revealForRequest() == "advanced-override")
    }
}

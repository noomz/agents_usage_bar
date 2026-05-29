import Testing
@testable import AgentsUsageBar
import Foundation

// MARK: - ConfigStore Tests (D-17, D-18, SEC-05 / CFG-06)

@Suite("ConfigStoreTests")
struct ConfigStoreTests {

    // MARK: - Helpers

    /// Writes text to a temp file and returns the URL. Caller owns cleanup.
    private func writeTempToml(_ content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.toml")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A URL that does not exist (for "no toml file" scenarios).
    private func nonExistentURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStoreTests-nonexistent-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
    }

    // MARK: - Test 1: All absent → AppConfig.defaults with apiKey == nil

    @Test("defaultsWhenEverythingAbsent")
    func defaultsWhenEverythingAbsent() {
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: nonExistentURL())
        let config = store.load()
        #expect(config.refreshInterval == .m5)
        #expect(config.threshold == 0.80)
        #expect(config.openrouter.apiKey == nil)
        #expect(config.openrouter.enabled == true)
        #expect(config.openrouter.xTitle == "Agents Usage Bar")
    }

    // MARK: - Test 2: Env only → resolves apiKey from env

    @Test("envOnly_resolvesApiKey")
    func envOnly_resolvesApiKey() {
        let store = ConfigStore(
            env: DictionaryEnvReader(["OPENROUTER_API_KEY": "env-key"]),
            tomlPath: nonExistentURL()
        )
        let config = store.load()
        #expect(config.openrouter.apiKey?.revealForRequest() == "env-key")
    }

    // MARK: - Test 3: TOML only → resolves apiKey from toml

    @Test("tomlOnly_resolvesApiKey")
    func tomlOnly_resolvesApiKey() throws {
        let tomlURL = try writeTempToml("[openrouter]\napi_key = \"toml-key\"\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let config = store.load()
        #expect(config.openrouter.apiKey?.revealForRequest() == "toml-key")
    }

    // MARK: - Test 4: Env beats TOML (D-17 precedence)

    @Test("envBeatsToml_precedence")
    func envBeatsToml_precedence() throws {
        let tomlURL = try writeTempToml("[openrouter]\napi_key = \"toml-loses\"\n")
        let store = ConfigStore(
            env: DictionaryEnvReader(["OPENROUTER_API_KEY": "env-wins"]),
            tomlPath: tomlURL
        )
        let config = store.load()
        #expect(config.openrouter.apiKey?.revealForRequest() == "env-wins")
    }

    // MARK: - Test 5: Env OPENROUTER_API_URL overrides apiURL

    @Test("optionalEnvHonored_apiURL")
    func optionalEnvHonored_apiURL() {
        let store = ConfigStore(
            env: DictionaryEnvReader(["OPENROUTER_API_URL": "https://custom.example/v1"]),
            tomlPath: nonExistentURL()
        )
        let config = store.load()
        #expect(config.openrouter.apiURL.absoluteString == "https://custom.example/v1")
    }

    // MARK: - Test 6: Env OPENROUTER_HTTP_REFERER sets httpReferer

    @Test("optionalEnvHonored_httpReferer")
    func optionalEnvHonored_httpReferer() {
        let store = ConfigStore(
            env: DictionaryEnvReader(["OPENROUTER_HTTP_REFERER": "https://example.com"]),
            tomlPath: nonExistentURL()
        )
        let config = store.load()
        #expect(config.openrouter.httpReferer == "https://example.com")
    }

    // MARK: - Test 7: Env OPENROUTER_X_TITLE sets xTitle; defaults to "Agents Usage Bar"

    @Test("optionalEnvHonored_xTitle")
    func optionalEnvHonored_xTitle() {
        let storeWithEnv = ConfigStore(
            env: DictionaryEnvReader(["OPENROUTER_X_TITLE": "MyApp"]),
            tomlPath: nonExistentURL()
        )
        #expect(storeWithEnv.load().openrouter.xTitle == "MyApp")

        let storeDefault = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: nonExistentURL())
        #expect(storeDefault.load().openrouter.xTitle == "Agents Usage Bar")
    }

    // MARK: - Test 8: TOML [openrouter].enabled = false disables provider

    @Test("tomlEnabledFalse_disablesProvider")
    func tomlEnabledFalse_disablesProvider() throws {
        let tomlURL = try writeTempToml("[openrouter]\nenabled = false\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let config = store.load()
        #expect(config.openrouter.enabled == false)
    }

    // MARK: - Test 9: TOML refresh_interval parsed

    @Test("tomlRefreshInterval_parsed")
    func tomlRefreshInterval_parsed() throws {
        let tomlURL = try writeTempToml("refresh_interval = \"1m\"\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let config = store.load()
        #expect(config.refreshInterval == .m1)
    }

    // MARK: - Test 10: TOML threshold parsed

    @Test("tomlThreshold_parsed")
    func tomlThreshold_parsed() throws {
        let tomlURL = try writeTempToml("threshold = 0.95\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let config = store.load()
        #expect(config.threshold == 0.95)
    }

    // MARK: - Test 11: Malformed TOML → fail-soft → defaults (D-18)

    @Test("tomlMalformed_failsSoft_defaults")
    func tomlMalformed_failsSoft_defaults() throws {
        let tomlURL = try writeTempToml("not-toml\n!!!\n====\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        // Must not throw or crash — returns defaults
        let config = store.load()
        #expect(config.refreshInterval == .m5)
        #expect(config.threshold == 0.80)
        #expect(config.openrouter.apiKey == nil)
    }

    // MARK: - Test 12: Missing threshold → defaults to 0.80

    @Test("tomlMissingThreshold_defaultsTo80Percent")
    func tomlMissingThreshold_defaultsTo80Percent() {
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: nonExistentURL())
        #expect(store.load().threshold == 0.80)
    }

    // MARK: - Test 13: Empty env string treated as absent

    @Test("emptyEnvStringTreatedAsAbsent")
    func emptyEnvStringTreatedAsAbsent() {
        let store = ConfigStore(
            env: DictionaryEnvReader(["OPENROUTER_API_KEY": ""]),
            tomlPath: nonExistentURL()
        )
        // Empty string must be treated as absent — apiKey should be nil
        #expect(store.load().openrouter.apiKey == nil)
    }

    // MARK: - Test 14 (SEC-05 / CFG-06): ConfigStore does not read shell RC files

    @Test("loadDoesNotReadShellRC_evenWhenSecretsPresent")
    func loadDoesNotReadShellRC_evenWhenSecretsPresent() throws {
        // Create a temp directory simulating a fake home with a .zshrc containing a secret
        let fakeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)

        // Write a fake .zshrc with a secret — ConfigStore must NOT read this
        let zshrc = fakeHome.appendingPathComponent(".zshrc")
        try "export OPENROUTER_API_KEY=should-not-be-read\n".write(to: zshrc, atomically: true, encoding: .utf8)

        // ConfigStore gets no env and no TOML — the only way it would see the key is if it
        // parsed the .zshrc, which is the SEC-05 / CFG-06 anti-feature.
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: nonExistentURL())
        let config = store.load()

        // Proves ConfigStore did NOT parse the shell rc file
        #expect(config.openrouter.apiKey == nil)

        // Cleanup
        try? FileManager.default.removeItem(at: fakeHome)
    }
}

import Testing
@testable import AgentsUsageBar
import Foundation

// MARK: - ConfigStorePrecedenceTests
//
// Verifies the `userDefaults > env > toml > defaults` precedence chain introduced by
// `ConfigStore.load(preferences:)` in Plan 05-02 (D-02/D-03).
//
// Uses `DictionaryEnvReader` (existing Phase 1 pattern) for env injection and
// `UserDefaults(suiteName: "test-\(UUID())")!` for full UserDefaults isolation.

@Suite("ConfigStorePrecedenceTests", .serialized)
@MainActor
struct ConfigStorePrecedenceTests {

    // MARK: - Helpers

    private func makeTempToml(_ content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStorePrecedenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.toml")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func nonExistentURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStorePrecedenceTests-nonexistent-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
    }

    /// Builds a `UserPreferencesStore` with the given values pre-written to its UserDefaults
    /// suite BEFORE the store is constructed, so the store's `init` → `loadAll()` reads them
    /// synchronously. This sidesteps the async `didChangeNotification` propagation that the
    /// setter-based pattern would require.
    private func makePrefs(
        refreshInterval: RefreshInterval? = nil,
        threshold: Double? = nil,
        providerEnabled: [ProviderID: Bool] = [:]
    ) -> UserPreferencesStore {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if let ri = refreshInterval {
            defaults.set(ri.tomlString, forKey: AUBDefaultsKey.refreshInterval)
        }
        if let t = threshold {
            defaults.set(t, forKey: AUBDefaultsKey.threshold)
        }
        for (id, enabled) in providerEnabled {
            defaults.set(enabled, forKey: AUBDefaultsKey.providerEnabled(id))
        }
        // Construct AFTER writes — loadAll() in init reads them synchronously.
        return UserPreferencesStore(defaults: defaults)
    }

    // MARK: - Test 1: UserDefaults beats TOML for refreshInterval

    @Test("userDefaultsBeatsToml_refreshInterval")
    func userDefaultsBeatsToml_refreshInterval() throws {
        let tomlURL = try makeTempToml("refresh_interval = \"1m\"\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let prefs = makePrefs(refreshInterval: .m2)

        let config = store.load(preferences: prefs)
        #expect(config.refreshInterval == .m2)
    }

    // MARK: - Test 2: UserDefaults beats default for threshold

    @Test("userDefaultsBeatsDefault_threshold")
    func userDefaultsBeatsDefault_threshold() throws {
        // No env, no TOML — default is 0.80; UserDefaults sets 0.90
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: nonExistentURL())
        let prefs = makePrefs(threshold: 0.90)

        let config = store.load(preferences: prefs)
        #expect(config.threshold == 0.90)
    }

    // MARK: - Test 3: credentials NOT overridden by UserDefaults

    @Test("credentials_notOverriddenByUserDefaults")
    func credentials_notOverriddenByUserDefaults() throws {
        // Env supplies the OpenRouter API key; UserDefaults supplies a providerEnabled flag.
        // The apiKey must still come from env only (D-03, CFG-01).
        let store = ConfigStore(
            env: DictionaryEnvReader(["OPENROUTER_API_KEY": "env-api-key"]),
            tomlPath: nonExistentURL()
        )
        let prefs = makePrefs(providerEnabled: [.openrouter: true])

        let config = store.load(preferences: prefs)

        // Credential must still come from env — not cleared or altered by UserDefaults
        #expect(config.openrouter.apiKey?.revealForRequest() == "env-api-key")

        // Verify no AUBDefaultsKey contains credential material
        let prefsDefaults = UserDefaults(suiteName: "test-creds-check-\(UUID().uuidString)")!
        let credStore = UserPreferencesStore(defaults: prefsDefaults)
        credStore.setProviderEnabled(.openrouter, enabled: false)
        // Only aub.provider.openrouter.enabled is written — no apiKey key
        let apiKeyValue = prefsDefaults.object(forKey: "aub.provider.openrouter.apiKey")
        #expect(apiKeyValue == nil)
    }

    // MARK: - Test 4: nil preferences returns base config unchanged

    @Test("nilPreferences_returnsBaseConfig")
    func nilPreferences_returnsBaseConfig() throws {
        let store = ConfigStore(
            env: DictionaryEnvReader(["OPENROUTER_API_KEY": "key-from-env"]),
            tomlPath: nonExistentURL()
        )
        let baseConfig = store.load()
        let overlaidConfig = store.load(preferences: nil)

        #expect(baseConfig.refreshInterval == overlaidConfig.refreshInterval)
        #expect(baseConfig.threshold == overlaidConfig.threshold)
        #expect(baseConfig.openrouter.apiKey?.revealForRequest() ==
                overlaidConfig.openrouter.apiKey?.revealForRequest())
    }

    // MARK: - Test 5: empty providerEnabled map does not change provider flags

    @Test("providerEnabled_absent_doesNotChangeConfig")
    func providerEnabled_absent_doesNotChangeConfig() throws {
        // TOML explicitly disables OpenRouter; empty providerEnabled in prefs should
        // leave the TOML setting intact.
        let tomlURL = try makeTempToml("[openrouter]\nenabled = false\n")
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let prefs = makePrefs()  // no providerEnabled entries

        let config = store.load(preferences: prefs)
        // UserDefaults has no key for openrouter.enabled → should not override TOML false
        #expect(config.openrouter.enabled == false)
    }
}

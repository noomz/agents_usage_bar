import Testing
@testable import AgentsUsageBar
import Foundation

// MARK: - UserPreferencesStoreTests
//
// Verifies UserDefaults round-trip for all knobs and hot-reload notification behavior.
// Uses `UserDefaults(suiteName: "test-\(UUID())")!` per test for full isolation (Research Q13).
//
// `@Suite(.serialized)` because `UserDefaults.didChangeNotification` on `.standard` is global —
// though we use isolated suites, concurrent test runs can still race on the notification bus.

@Suite("UserPreferencesStoreTests", .serialized)
@MainActor
struct UserPreferencesStoreTests {

    // MARK: - Helpers

    /// Creates a fully isolated UserDefaults suite for a single test.
    private func makeDefaults() -> UserDefaults {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return defaults
    }

    // MARK: - Test 1: refreshInterval round-trip

    @Test("roundTrip_refreshInterval")
    func roundTrip_refreshInterval() async throws {
        let defaults = makeDefaults()
        let store = UserPreferencesStore(defaults: defaults)
        store.setRefreshInterval(.m1)
        // Wait for didChangeNotification → loadAll()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.refreshInterval == .m1)
    }

    // MARK: - Test 2: threshold round-trip

    @Test("roundTrip_threshold")
    func roundTrip_threshold() async throws {
        let defaults = makeDefaults()
        let store = UserPreferencesStore(defaults: defaults)
        store.setThreshold(0.90)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.threshold == 0.90)
    }

    // MARK: - Test 3: theme round-trip

    @Test("roundTrip_theme")
    func roundTrip_theme() async throws {
        let defaults = makeDefaults()
        let store = UserPreferencesStore(defaults: defaults)
        store.setTheme(.dark)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.theme == .dark)
    }

    // MARK: - Test 4: openAtLogin round-trip

    @Test("roundTrip_openAtLogin")
    func roundTrip_openAtLogin() async throws {
        let defaults = makeDefaults()
        let store = UserPreferencesStore(defaults: defaults)
        store.setOpenAtLogin(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.openAtLogin == true)
    }

    // MARK: - Test 5: hasSeenWelcome round-trip

    @Test("roundTrip_hasSeenWelcome")
    func roundTrip_hasSeenWelcome() async throws {
        let defaults = makeDefaults()
        let store = UserPreferencesStore(defaults: defaults)
        store.setHasSeenWelcome(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.hasSeenWelcome == true)
    }

    // MARK: - Test 6: providerEnabled round-trip

    @Test("roundTrip_providerEnabled")
    func roundTrip_providerEnabled() async throws {
        let defaults = makeDefaults()
        let store = UserPreferencesStore(defaults: defaults)
        store.setProviderEnabled(.openrouter, enabled: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.providerEnabled[.openrouter] == false)
    }

    // MARK: - Test 6b: claudeSource round-trip

    @Test("roundTrip_claudeSource")
    func roundTrip_claudeSource() async throws {
        let defaults = makeDefaults()
        let store = UserPreferencesStore(defaults: defaults)
        store.setClaudeSource(.hook)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.claudeSource == .hook)
    }

    // MARK: - Test 6c: claudeSource default is .sessionReads

    @Test("claudeSource_defaultsToSessionReads")
    func claudeSource_defaultsToSessionReads() {
        let defaults = makeDefaults()
        #expect(defaults.object(forKey: AUBDefaultsKey.claudeSource) == nil)
        let store = UserPreferencesStore(defaults: defaults)
        #expect(store.claudeSource == .sessionReads)
    }

    // MARK: - Test 6d: unknown claudeSource rawValue falls back to default

    @Test("claudeSource_unknownRawValue_fallsBackToSessionReads")
    func claudeSource_unknownRawValue_fallsBackToSessionReads() {
        let defaults = makeDefaults()
        defaults.set("garbage", forKey: AUBDefaultsKey.claudeSource)
        let store = UserPreferencesStore(defaults: defaults)
        #expect(store.claudeSource == .sessionReads)
    }

    // MARK: - Test 7: fresh store defaults match expected

    @Test("freshStore_defaultsMatchExpected")
    func freshStore_defaultsMatchExpected() {
        let defaults = makeDefaults()
        let store = UserPreferencesStore(defaults: defaults)
        #expect(store.refreshInterval == .m5)
        #expect(store.threshold == 0.80)
        #expect(store.theme == .auto)
        #expect(store.openAtLogin == false)
        #expect(store.hasSeenWelcome == false)
        #expect(store.claudeSource == .sessionReads)
        #expect(store.providerEnabled.isEmpty == true)
    }

    // MARK: - Test 8: change notification reloads properties

    @Test("changeNotification_reloadsProperties")
    func changeNotification_reloadsProperties() async throws {
        let defaults = makeDefaults()
        let store = UserPreferencesStore(defaults: defaults)

        // Write directly to the underlying UserDefaults (bypasses the store setter)
        // to simulate an external change — UserDefaults.didChangeNotification should
        // fire and update the store.
        defaults.set(AppTheme.light.rawValue, forKey: AUBDefaultsKey.theme)

        // Wait for the notification to fire and loadAll() to complete
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.theme == .light)
    }

    // MARK: - Test 9: absent threshold key does not override default to 0.0

    @Test("absentKey_doesNotOverrideDefaultThreshold")
    func absentKey_doesNotOverrideDefaultThreshold() {
        let defaults = makeDefaults()
        // Verify no key exists
        #expect(defaults.object(forKey: AUBDefaultsKey.threshold) == nil)
        let store = UserPreferencesStore(defaults: defaults)
        // `double(forKey:)` returns 0.0 for absent keys — `UserPreferencesStore` must use
        // `object(forKey:) as? Double` to distinguish "not set" from "set to 0".
        #expect(store.threshold == 0.80)
    }
}

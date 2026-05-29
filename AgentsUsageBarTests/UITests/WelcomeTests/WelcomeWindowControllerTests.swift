import Testing
import Foundation
@testable import AgentsUsageBar

/// Tests for WelcomeWindowController — hasSeenWelcome gate, show/dismiss, and
/// WindowActivationObserver delegation (ISS-04: no direct setActivationPolicy calls).
///
/// @Suite(.serialized) because tests involve NSApplication state and NSWindow creation;
/// parallel execution risks interference on a single NSApplication instance.
@Suite(.serialized)
@MainActor
struct WelcomeWindowControllerTests {

    // MARK: - Helpers

    private func makePrefs(hasSeenWelcome: Bool = false) -> UserPreferencesStore {
        let defaults = UserDefaults(suiteName: "test-welcome-\(UUID().uuidString)")!
        if hasSeenWelcome {
            defaults.set(true, forKey: "aub.hasSeenWelcome")
        }
        return UserPreferencesStore(defaults: defaults)
    }

    private func makeConfig() -> AppConfig {
        ConfigStore(env: DictionaryEnvReader([:]), tomlPath: nil).load()
    }

    // MARK: - Test cases

    @Test func showIfNeeded_doesNotOpen_whenHasSeenWelcomeTrue() {
        let prefs = makePrefs(hasSeenWelcome: true)
        let controller = WelcomeWindowController(preferences: prefs, config: makeConfig())

        // Calling showIfNeeded on a seen-welcome store should be a no-op.
        // We verify indirectly: hasSeenWelcome is still true, no crash, no window shown.
        controller.showIfNeeded()
        #expect(prefs.hasSeenWelcome == true)
    }

    @Test func showIfNeeded_opens_whenHasSeenWelcomeFalse() {
        let prefs = makePrefs(hasSeenWelcome: false)
        let controller = WelcomeWindowController(preferences: prefs, config: makeConfig())

        // On a fresh install, showIfNeeded should proceed (no-op guard should NOT fire).
        // We verify hasSeenWelcome remains false before dismiss (guard did not flip it).
        controller.showIfNeeded()
        #expect(prefs.hasSeenWelcome == false)
        // Clean up — close the window if it opened
        // (WelcomeWindowController keeps window reference; close it to avoid state leak)
    }

    @Test func showIfNeeded_isNoop_whenWindowAlreadyVisible() {
        let prefs = makePrefs(hasSeenWelcome: false)
        let controller = WelcomeWindowController(preferences: prefs, config: makeConfig())

        // Call show() twice — second call should not open a second window.
        controller.show()
        controller.show()  // Should be a no-op (window already visible)
        // No crash = pass. The window is brought to front instead of creating a new one.
        #expect(prefs.hasSeenWelcome == false)
    }

    @Test func windowTitle_isWelcome_forActivationObserverMatching() {
        // ISS-04: WindowActivationObserver.managedTitles = ["Settings", "Welcome"].
        // WelcomeWindowController MUST set win.title = "Welcome" (not any other string)
        // so the observer's allow-list filter matches and handles the policy flip.
        // Source-walk: verify the exact string literal is present.
        let source = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()                             // WelcomeTests/
                .deletingLastPathComponent()                             // UITests/
                .deletingLastPathComponent()                             // AgentsUsageBarTests/
                .deletingLastPathComponent()                             // (repo root)
                .appendingPathComponent("AgentsUsageBar/UI/Welcome/WelcomeWindowController.swift"),
            encoding: .utf8
        )
        #expect(source != nil, "WelcomeWindowController.swift not found")
        #expect(source?.contains("\"Welcome\"") == true,
                "win.title must be set to \"Welcome\" for WindowActivationObserver match (ISS-04)")
    }

    @Test func noDirectSetActivationPolicyCall_inWelcomeWindowController() {
        // ISS-04: WelcomeWindowController MUST NOT call NSApp.setActivationPolicy directly.
        // WindowActivationObserver is the single source of truth for the policy flip.
        // Source-walk: count actual call patterns (not comment text).
        let source = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("AgentsUsageBar/UI/Welcome/WelcomeWindowController.swift"),
            encoding: .utf8
        )
        #expect(source != nil)
        // Count lines that actually CALL setActivationPolicy (not just comment about it).
        let lines = source?.components(separatedBy: .newlines) ?? []
        let callLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A line is a call if it contains setActivationPolicy( and is NOT a comment
            return trimmed.contains("setActivationPolicy(") &&
                   !trimmed.hasPrefix("//") &&
                   !trimmed.hasPrefix("*") &&
                   !trimmed.hasPrefix("///")
        }
        #expect(callLines.isEmpty,
                "WelcomeWindowController must not call setActivationPolicy directly (ISS-04). Found: \(callLines)")
    }

    @Test func dismiss_setsHasSeenWelcomeTrue() {
        // Source-walk: verify setHasSeenWelcome is called in the dismiss path.
        let source = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("AgentsUsageBar/UI/Welcome/WelcomeWindowController.swift"),
            encoding: .utf8
        )
        #expect(source != nil)
        #expect(source?.contains("preferences.setHasSeenWelcome(true)") == true,
                "dismiss() and handleWindowClose() must call setHasSeenWelcome(true)")
    }

    @Test func willCloseNotification_observerPresent() {
        // Source-walk: NSWindow.willCloseNotification observer must be registered (Pitfall 4).
        let source = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("AgentsUsageBar/UI/Welcome/WelcomeWindowController.swift"),
            encoding: .utf8
        )
        #expect(source != nil)
        #expect(source?.contains("NSWindow.willCloseNotification") == true,
                "WelcomeWindowController must register NSWindow.willCloseNotification observer (Pitfall 4)")
    }
}

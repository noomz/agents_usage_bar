import Testing
import Foundation

/// Plan 05-03 — Structural source-grep tests for `SettingsGeneralTab.swift`.
///
/// These tests verify the file contains the required UI controls, binding patterns, and
/// security invariants — without requiring a running SwiftUI host or snapshot framework.
///
/// Pattern mirrors `FooterViewTests` (W7 source-grep contract tests).
@MainActor
@Suite("SettingsGeneralTab source-grep contract tests (Plan 05-03)")
struct SettingsGeneralTabTests {

    /// Reads `SettingsGeneralTab.swift` using `#filePath`-based repo-root walk.
    private func settingsGeneralTabSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()  // SettingsTests/
            .deletingLastPathComponent()  // UITests/
            .deletingLastPathComponent()  // AgentsUsageBarTests/
            .deletingLastPathComponent()  // repo root
        let sourcePath = repoRoot.appendingPathComponent(
            "AgentsUsageBar/UI/Settings/SettingsGeneralTab.swift"
        )
        return try String(contentsOf: sourcePath, encoding: .utf8)
    }

    @Test("SettingsGeneralTab contains refresh interval Picker with RefreshInterval tags")
    func settingsGeneralTab_containsRefreshIntervalPicker() throws {
        let source = try settingsGeneralTabSource()
        #expect(source.contains("Picker"), "Source must contain a Picker for refresh interval")
        #expect(source.contains("RefreshInterval.manual"), "Source must contain RefreshInterval.manual tag")
        #expect(source.contains("RefreshInterval.m5"), "Source must contain RefreshInterval.m5 tag")
    }

    @Test("SettingsGeneralTab contains threshold Slider with range 0.5...0.95")
    func settingsGeneralTab_containsThresholdSlider() throws {
        let source = try settingsGeneralTabSource()
        #expect(source.contains("Slider"), "Source must contain a Slider for threshold control")
        #expect(source.contains("0.5...0.95"), "Slider range must be exactly 0.5...0.95 per Discretion")
    }

    @Test("SettingsGeneralTab contains pace-warnings Toggle bound to preferences")
    func settingsGeneralTab_containsPaceWarningsToggle() throws {
        let source = try settingsGeneralTabSource()
        #expect(source.contains("Warn if usage is on pace to hit limits"))
        #expect(source.contains("paceWarningsEnabled"))
        #expect(source.contains("setPaceWarningsEnabled"))
    }

    @Test("SettingsGeneralTab contains reset-notifications Toggle bound to preferences")
    func settingsGeneralTab_containsResetNotificationsToggle() throws {
        let source = try settingsGeneralTabSource()
        #expect(source.contains("Notify when limits reset"))
        #expect(source.contains("resetNotificationsEnabled"))
        #expect(source.contains("setResetNotificationsEnabled"))
    }

    @Test("SettingsGeneralTab contains theme Picker with AppTheme tags")
    func settingsGeneralTab_containsThemePicker() throws {
        let source = try settingsGeneralTabSource()
        #expect(source.contains("AppTheme.light"), "Source must contain AppTheme.light tag")
        #expect(source.contains("AppTheme.dark"), "Source must contain AppTheme.dark tag")
        #expect(source.contains("AppTheme.auto"), "Source must contain AppTheme.auto tag")
    }

    @Test("SettingsGeneralTab contains SMAppService deep-link URL (D-08)")
    func settingsGeneralTab_smAppService_deepLinkURL() throws {
        let source = try settingsGeneralTabSource()
        #expect(
            source.contains("x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
            "Source must contain the Login Items deep-link URL per D-08"
        )
    }

    @Test("SettingsGeneralTab reverts open-at-login silently — no toast, no alert (Discretion)")
    func settingsGeneralTab_silentRevert_noToast() throws {
        let source = try settingsGeneralTabSource()
        // Silence on failure: no Toast, no Alert, no showDialog. Only os.Logger warning.
        #expect(!source.contains("Toast"), "SettingsGeneralTab must not use a Toast on SMAppService failure")
        #expect(!source.contains("showDialog"), "SettingsGeneralTab must not use showDialog on failure")
        // Verify the warning logger path IS present (correct silent-revert pattern)
        #expect(source.contains("logger.warning"), "Source must log the failure via logger.warning")
    }

    @Test("SettingsGeneralTab embeds CLIInstallSection")
    func settingsGeneralTab_containsCLIInstallSection() throws {
        let source = try settingsGeneralTabSource()
        #expect(source.contains("CLIInstallSection()"), "General tab must offer one-click aub install")
        #expect(source.contains("Command Line") || source.contains("CLIInstallSection"))
    }
}

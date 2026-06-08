import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - SettingsProvidersTabTests
//
// Structural source-walk tests for SettingsProvidersTab.swift.
// These tests verify the presence of required patterns in the source file,
// acting as a regression gate for D-14 (DisclosureGroup), D-15 (NSPasteboard),
// D-16 (ProviderID.allKnown), and CFG-06 (no shell RC references).

@MainActor
@Suite("SettingsProvidersTabTests")
struct SettingsProvidersTabTests {

    private static let source: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SettingsTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // AgentsUsageBarTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("AgentsUsageBar/UI/Settings/SettingsProvidersTab.swift")
        return (try? String(contentsOf: url)) ?? ""
    }()

    @Test func settingsProvidersTab_usesAllKnown() {
        // D-14: tab iterates ProviderID.allKnown to render all 7 provider rows
        #expect(
            Self.source.contains("ProviderID.allKnown"),
            "SettingsProvidersTab must iterate ProviderID.allKnown"
        )
    }

    @Test func settingsProvidersTab_usesDisclosureGroup() {
        // D-14: expandable "How to enable" panel must use SwiftUI DisclosureGroup
        #expect(
            Self.source.contains("DisclosureGroup"),
            "SettingsProvidersTab must use DisclosureGroup for expandable help panel (D-14)"
        )
    }

    @Test func settingsProvidersTab_usesPasteboard() {
        // D-15: Copy-to-clipboard buttons must use NSPasteboard.general
        #expect(
            Self.source.contains("NSPasteboard.general"),
            "SettingsProvidersTab must use NSPasteboard.general for copy buttons (D-15)"
        )
    }

    @Test func cfg06_noShellRcReferences_inProvidersTab() {
        // CFG-06: SettingsProvidersTab must never reference shell RC file paths
        // Check for quoted string literals (not doc comments) containing RC paths
        #expect(
            !Self.source.contains("\"/.zshrc\""),
            "SettingsProvidersTab must not reference .zshrc"
        )
        #expect(
            !Self.source.contains("\"/.bashrc\""),
            "SettingsProvidersTab must not reference .bashrc"
        )
        #expect(
            !Self.source.contains("\"config.fish\""),
            "SettingsProvidersTab must not reference config.fish"
        )
    }
}

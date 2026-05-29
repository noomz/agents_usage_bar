import Testing
import Foundation
@testable import AgentsUsageBar

/// Structural source-walk tests for WelcomeRootView.
///
/// These tests verify that the WelcomeRootView source file contains the required
/// structural elements: ProviderID.allKnown iteration, DetectionProbe.probeAll call,
/// provider seeding, footer buttons, and CFG-06 compliance.
struct WelcomeRootViewTests {

    private func loadSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                 // WelcomeTests/
            .deletingLastPathComponent()                 // UITests/
            .deletingLastPathComponent()                 // AgentsUsageBarTests/
            .deletingLastPathComponent()                 // (repo root)
            .appendingPathComponent("AgentsUsageBar/UI/Welcome/WelcomeRootView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func welcomeRootView_usesAllKnown() throws {
        // WelcomeRootView must iterate ProviderID.allKnown to render all 7 provider rows.
        let source = try loadSource()
        #expect(source.contains("ProviderID.allKnown"),
                "WelcomeRootView must use ProviderID.allKnown to enumerate providers")
    }

    @Test func welcomeRootView_callsDetectionProbeProbeAll() throws {
        // WelcomeRootView must call DetectionProbe.probeAll to run detection on appear (D-13).
        let source = try loadSource()
        #expect(source.contains("DetectionProbe.probeAll"),
                "WelcomeRootView must call DetectionProbe.probeAll for welcome-time detection")
    }

    @Test func welcomeRootView_seedsDetectedProviders_inPreferences() throws {
        // WelcomeRootView must call preferences.setProviderEnabled to seed detected
        // providers on first launch (CFG-03 + D-11).
        let source = try loadSource()
        #expect(source.contains("preferences.setProviderEnabled"),
                "WelcomeRootView must call preferences.setProviderEnabled to seed detected providers (D-11)")
    }

    @Test func welcomeRootView_hasTwoFooterButtons() throws {
        // WelcomeRootView must have both footer buttons (D-10 trigger sources).
        let source = try loadSource()
        #expect(source.contains("\"Get Started\""),
                "WelcomeRootView must have a 'Get Started' footer button")
        #expect(source.contains("\"Open Settings\""),
                "WelcomeRootView must have an 'Open Settings' footer button")
    }

    @Test func cfg06_noShellRcReferences_inWelcomeRootView() throws {
        // CFG-06 anti-feature: WelcomeRootView must never reference shell RC files.
        let source = try loadSource()
        #expect(!source.contains(".zshrc"),
                "CFG-06 violation: WelcomeRootView must not reference .zshrc")
        #expect(!source.contains(".bashrc"),
                "CFG-06 violation: WelcomeRootView must not reference .bashrc")
        #expect(!source.contains("config.fish"),
                "CFG-06 violation: WelcomeRootView must not reference config.fish")
    }
}

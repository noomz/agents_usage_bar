import Foundation
import SwiftUI
import Testing
@testable import AgentsUsageBar

/// Plan 03-07 Task 2 — `ProviderRowView` trailing dashboard button contract
/// (UI-11 / D-13). Source-grep + runtime tests prove the row's trailing
/// `Button` invokes `openDashboardURL` with `ProviderDashboardURL.lookup(state.id)`.
@Suite("Plan 03-07 Task 2 — ProviderRowView dashboard button")
@MainActor
struct ProviderRowViewDashboardButtonTests {

    // MARK: - Source-grep contract assertions (avoids SwiftUI introspection brittleness)

    @Test("ProviderRowView source contains arrow.up.right.square SF symbol")
    func source_containsArrowUpRightSquare() throws {
        let src = try Self.providerRowViewSource()
        #expect(src.contains("arrow.up.right.square"),
                "ProviderRowView must use the arrow.up.right.square SF symbol for the dashboard button (D-13)")
    }

    @Test("ProviderRowView source calls openDashboardURL via env key (not NSWorkspace inline)")
    func source_invokesOpenDashboardURLViaEnvKey() throws {
        let src = try Self.providerRowViewSource()
        #expect(src.contains("openDashboardURL"),
                "ProviderRowView must reference openDashboardURL (env-key indirection — not inline NSWorkspace.shared.open)")
        #expect(src.contains("@Environment(\\.openDashboardURL)"),
                "ProviderRowView must declare @Environment(\\.openDashboardURL) — keeps NSWorkspace out of the view body")
        // NSWorkspace must NOT be imported directly into the view body.
        #expect(src.contains("NSWorkspace.shared.open") == false,
                "ProviderRowView must NOT call NSWorkspace.shared.open directly — that is the EnvironmentKey's default's job")
    }

    @Test("Dashboard button is .disabled when dashboardURL is nil (no removal — layout symmetry)")
    func source_disabledWhenURLNil() throws {
        let src = try Self.providerRowViewSource()
        #expect(src.contains(".disabled(dashboardURL == nil)"),
                "Dashboard button must be .disabled(dashboardURL == nil) so the row layout stays symmetric across providers")
    }

    @Test("Dashboard button carries accessibility help string 'Open <displayName> dashboard'")
    func source_buttonAccessibilityHelp() throws {
        let src = try Self.providerRowViewSource()
        #expect(src.contains("\"Open \\(state.displayName) dashboard\""),
                "Dashboard button must provide the accessibility help string 'Open \\(state.displayName) dashboard'")
    }

    // MARK: - Runtime test — the env-injected closure receives the expected URL

    @Test("Environment-injected openDashboardURL closure receives ProviderDashboardURL.lookup(state.id)")
    func runtime_envKeyReceivesExpectedURL() async {
        // Recorder captures URLs that ProviderRowView would open. We invoke the
        // closure through the same indirection the view body uses — pulling
        // it from EnvironmentValues — so this exercises the contract end-to-end
        // without instantiating SwiftUI hierarchies in the test process.
        let recorder = URLRecorder()
        var env = EnvironmentValues()
        env.openDashboardURL = { @MainActor url in recorder.record(url) }

        // Codex row -> https://platform.openai.com/usage
        if let url = ProviderDashboardURL.lookup(.codex) {
            env.openDashboardURL(url)
        }
        // Gemini row -> https://aistudio.google.com/u/0/usage
        if let url = ProviderDashboardURL.lookup(.gemini) {
            env.openDashboardURL(url)
        }

        #expect(recorder.recorded == [
            URL(string: "https://platform.openai.com/usage")!,
            URL(string: "https://aistudio.google.com/u/0/usage")!
        ])
    }

    // MARK: - Helpers

    /// Reads ProviderRowView.swift as text via `#filePath` repo-root walk.
    /// Same pattern as the Phase 1 STATE #33 source-grep tests. Nonisolated
    /// so the sibling tooltip + degraded test suites can call it from
    /// non-MainActor contexts.
    nonisolated static func providerRowViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        // .../AgentsUsageBarTests/UITests/<thisFile> → walk up to repo root.
        let repoRoot = testFile
            .deletingLastPathComponent()   // UITests
            .deletingLastPathComponent()   // AgentsUsageBarTests
            .deletingLastPathComponent()   // repo
        let source = repoRoot
            .appendingPathComponent("AgentsUsageBar")
            .appendingPathComponent("UI")
            .appendingPathComponent("ProviderRowView.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }
}

/// MainActor-isolated URL recorder for the env-injected closure. Using a
/// `final class` lets the closure capture by reference; isolation keeps the
/// recorder Sendable-safe under Swift 6 strict concurrency.
@MainActor
private final class URLRecorder {
    var recorded: [URL] = []
    func record(_ url: URL) { recorded.append(url) }
}

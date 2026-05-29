import Testing
import Foundation

/// W7 source-grep tests for `FooterView.swift`.
///
/// These tests verify FooterView.swift's source code contains the required patterns,
/// proving that:
///   (a) Cmd-R keyboard shortcut is wired
///   (b) store.refresh call site exists
///   (c) @Environment(\.clockService) is consumed (B5: FooterView CONSUMES, does NOT redeclare ClockKey)
///
/// Path resolution uses #filePath-based walking to locate FooterView.swift at the repo root.
@Suite("FooterView source-grep contract tests (W7)")
struct FooterViewTests {

    /// Reads the FooterView.swift source file using #filePath-based repo-root walk.
    private func footerViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()  // UITests/
            .deletingLastPathComponent()  // AgentsUsageBarTests/
            .deletingLastPathComponent()  // repo root
        let footerPath = repoRoot.appendingPathComponent("AgentsUsageBar/UI/FooterView.swift")
        return try String(contentsOf: footerPath, encoding: .utf8)
    }

    @Test("FooterView.swift contains Cmd-R keyboard shortcut (UI-10)")
    func containsCmdRShortcut() throws {
        let source = try footerViewSource()
        #expect(source.contains(".keyboardShortcut(\"r\", modifiers: .command)"),
                "FooterView.swift must contain .keyboardShortcut(\"r\", modifiers: .command) for Cmd-R refresh")
    }

    @Test("FooterView.swift contains store.refresh call site")
    func containsStoreRefreshCall() throws {
        let source = try footerViewSource()
        #expect(source.contains("store.refresh(now:"),
                "FooterView.swift must contain store.refresh(now:) to trigger refresh")
    }

    @Test("FooterView.swift consumes @Environment(\\.clockService) but does NOT redeclare ClockKey or extend EnvironmentValues (B5)")
    func consumesClockServiceWithoutRedeclaration() throws {
        let source = try footerViewSource()
        // B5: FooterView MUST consume the key
        #expect(source.contains("@Environment(\\.clockService)"),
                "FooterView.swift must consume @Environment(\\.clockService)")
        // B5: FooterView must NOT redeclare the key (sole owner is ClockEnvironmentKey.swift)
        #expect(!source.contains("struct ClockKey"),
                "FooterView.swift must NOT declare struct ClockKey (sole owner: ClockEnvironmentKey.swift)")
        #expect(!source.contains("extension EnvironmentValues"),
                "FooterView.swift must NOT extend EnvironmentValues (sole owner: ClockEnvironmentKey.swift)")
    }
}

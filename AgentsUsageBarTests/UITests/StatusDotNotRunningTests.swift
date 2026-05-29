import Testing
import SwiftUI
@testable import AgentsUsageBar

/// Plan 04-01 / T-04-01-04 — verifies `StatusDot` renders `.notRunning` as
/// gray (LOCAL-04 muted-never-red) and that the `forceAmber` / `isStale`
/// composition rules are preserved (Phase 3 STATE #90).
///
/// Because `dotColor` is `private`, the tests use source-grep via `#filePath`
/// to anchor the structural contracts, mirroring the Phase 1/3 W-7 precedent
/// (`FooterViewTests`, `ProviderRowViewDegradedTests`).
@Suite("StatusDotNotRunningTests")
struct StatusDotNotRunningTests {

    // MARK: - Source-grep helpers

    private static func statusDotSource() throws -> String {
        // Walk up from this test file to the repo root, then find StatusDot.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        // #filePath: .../AgentsUsageBarTests/UITests/StatusDotNotRunningTests.swift
        // Repo root is 3 levels up (UITests → AgentsUsageBarTests → repo root)
        let repoRoot = thisFile
            .deletingLastPathComponent() // UITests
            .deletingLastPathComponent() // AgentsUsageBarTests
            .deletingLastPathComponent() // repo root
        let statusDotURL = repoRoot
            .appendingPathComponent("AgentsUsageBar/UI/Components/StatusDot.swift")
        return try String(contentsOf: statusDotURL, encoding: .utf8)
    }

    // MARK: - dotColor gray for .notRunning

    @Test("StatusDot.dotColor returns gray for .notRunning (source-grep gate)")
    func notRunning_dotColorIsGray() throws {
        let source = try Self.statusDotSource()
        let hasGrayArm = source.contains("case .notRunning:") && source.contains("base = .gray")
        #expect(hasGrayArm,
            "StatusDot.swift must contain 'case .notRunning:' arm with 'base = .gray'")
    }

    // MARK: - accessibilityLabel for .notRunning

    @Test("StatusDot.accessibilityLabel returns \"Status: Not running\" for .notRunning (source-grep gate)")
    func notRunning_accessibilityLabelIsCorrect() throws {
        let source = try Self.statusDotSource()
        #expect(source.contains("Status: Not running"),
            "StatusDot.swift must contain 'Status: Not running' in the accessibilityLabel switch arm")
    }

    // MARK: - isStale dims opacity

    @Test("notRunning with isStale=true produces gray.opacity(0.4) (source-grep gate)")
    func notRunning_isStaleDimsOpacity() throws {
        let source = try Self.statusDotSource()
        // The composition rule: isStale applies opacity(0.4) over resolved color.
        // Source must contain the opacity pattern from Phase 1 STATE #90.
        #expect(source.contains(".opacity(0.4)"),
            "StatusDot.swift must contain '.opacity(0.4)' for stale dimming")
        // And .notRunning must be in the dotColor switch (gray base before opacity)
        #expect(source.contains("case .notRunning:"),
            "StatusDot.swift must contain 'case .notRunning:' arm")
    }

    // MARK: - forceAmber overrides .notRunning

    @Test("notRunning with forceAmber=true overrides to orange (source-grep gate for composition rule)")
    func notRunning_forceAmberOverrides() throws {
        let source = try Self.statusDotSource()
        // Phase 3 STATE #90: forceAmber ? .orange : base
        #expect(source.contains("forceAmber ? .orange : base"),
            "StatusDot.swift must contain 'forceAmber ? .orange : base' composition rule")
    }
}

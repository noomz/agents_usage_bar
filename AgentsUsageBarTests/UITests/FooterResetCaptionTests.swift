import Testing
import Foundation

/// Plan 02.07 — UI-05 source-grep contract tests for `FooterView.swift`.
///
/// Mirrors the Phase 1 W7 pattern (`FooterViewTests`) — uses `#filePath`-based
/// repo-root walking to locate the source file, then asserts that the required
/// substrings are present. Direct SwiftUI body inspection is hostile, so the
/// contract is encoded as source-grep checks.
@MainActor
@Suite("FooterView reset-clock caption contract tests (UI-05)")
struct FooterResetCaptionTests {

    private func footerViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()  // UITests/
            .deletingLastPathComponent()  // AgentsUsageBarTests/
            .deletingLastPathComponent()  // repo root
        let footerPath = repoRoot.appendingPathComponent("AgentsUsageBar/UI/FooterView.swift")
        return try String(contentsOf: footerPath, encoding: .utf8)
    }

    @Test("FooterView.swift invokes TodayHelper.resetClockText(clock.now()) (UI-05)")
    func footerView_source_contains_resetClockText_invocation() throws {
        let source = try footerViewSource()
        #expect(source.contains("TodayHelper.resetClockText(clock.now())"),
                "FooterView.swift must invoke TodayHelper.resetClockText(clock.now()) for the UI-05 caption")
    }

    @Test("FooterView.swift uses .font(.caption2) on the reset-clock caption (UI-05)")
    func footerView_source_contains_caption2_font_for_resetCaption() throws {
        let source = try footerViewSource()
        // We look for .font(.caption2) AND TodayHelper.resetClockText to verify both
        // appear in the file (no formal proximity check — pure regex would be brittle).
        #expect(source.contains(".font(.caption2)"),
                "FooterView.swift must use .font(.caption2) for the small reset-clock caption")
        #expect(source.contains("TodayHelper.resetClockText"),
                "FooterView.swift must reference TodayHelper.resetClockText alongside the caption2 font")
    }
}

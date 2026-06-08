import Foundation
import Testing
@testable import AgentsUsageBar

/// Plan 04-07 T-03 — source-walk + view-contract tests for `ProviderRowView`
/// local-row branching.
///
/// Mirrors the Phase 3 STATE #91 source-grep pattern established in
/// `ProviderRowViewDashboardButtonTests` / `ProviderRowViewDegradedTests`.
///
/// Tests verify:
///   - `LocalRowSecondaryView` is referenced in the view source
///   - `if isLocal {` branch exists and `tokenText/usdText/balanceText` are
///     NOT reachable from inside it (LOCAL-06 anti-feature)
///   - Phase 3 invariants (dashboard button SF symbol, D-11 degraded subtitle)
///     are preserved unchanged
@MainActor
@Suite("Plan 04-07 — ProviderRowView local-row branching")
struct ProviderRowViewLocalRowTests {

    // MARK: - Source file helpers

    /// Reads ProviderRowView.swift as text via `#filePath` repo-root walk.
    /// `nonisolated` so it can be called from non-MainActor test contexts.
    nonisolated static func providerRowViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
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

    /// Reads LocalRowSecondaryView.swift as text.
    nonisolated static func localRowSecondaryViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repoRoot
            .appendingPathComponent("AgentsUsageBar")
            .appendingPathComponent("UI")
            .appendingPathComponent("Components")
            .appendingPathComponent("LocalRowSecondaryView.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    // MARK: - Source-walk contract assertions

    @Test("ProviderRowView references LocalRowSecondaryView and isLocal computed property")
    func providerRowView_referencesLocalRowSecondaryView() throws {
        let src = try Self.providerRowViewSource()
        #expect(src.contains("LocalRowSecondaryView"),
                "ProviderRowView must reference LocalRowSecondaryView for local rows (Plan 04-07)")
        #expect(src.contains("isLocal"),
                "ProviderRowView must declare/use the isLocal computed property")
        #expect(src.contains("ProviderID.localIDs.contains"),
                "ProviderRowView must key off ProviderID.localIDs.contains for the isLocal check")
    }

    @Test("ProviderRowView branches on 'if isLocal {' before dashboard button rendering")
    func providerRowView_branchesOnIsLocal() throws {
        let src = try Self.providerRowViewSource()
        #expect(src.contains("if isLocal {"),
                "ProviderRowView must contain 'if isLocal {' for the local-row branch")

        // Line-ordering invariant: 'if isLocal {' appears before 'arrow.up.right.square'
        // (the dashboard button is at the bottom of the row's VStack).
        if let isLocalRange = src.range(of: "if isLocal {"),
           let dashboardRange = src.range(of: "arrow.up.right.square") {
            #expect(isLocalRange.lowerBound < dashboardRange.lowerBound,
                    "The isLocal branch must appear BEFORE the dashboard button in the view body")
        }
    }

    @Test("LOCAL-06 anti-feature: tokenText/usdText/balanceText are inside 'else' branch only")
    func providerRowView_local06AntiFeature_localsNeverReachTokenText() throws {
        let src = try Self.providerRowViewSource()

        // Extract the content between `if isLocal {` and the matching `} else {`.
        // We verify that the LOCAL-06 cost/token helpers are NOT called within
        // the isLocal-true branch.
        guard let isLocalStart = src.range(of: "if isLocal {") else {
            Issue.record("ProviderRowView must contain 'if isLocal {'")
            return
        }

        // Find the `} else {` that closes the isLocal true-branch.
        let afterIsLocal = src[isLocalStart.upperBound...]
        guard let elseRange = afterIsLocal.range(of: "} else {") else {
            Issue.record("ProviderRowView must have '} else {' after 'if isLocal {'")
            return
        }

        let isLocalTrueBranch = String(afterIsLocal[afterIsLocal.startIndex..<elseRange.lowerBound])

        #expect(!isLocalTrueBranch.contains("tokenText("),
                "LOCAL-06: tokenText() must NOT be called inside the isLocal=true branch")
        #expect(!isLocalTrueBranch.contains("usdText("),
                "LOCAL-06: usdText() must NOT be called inside the isLocal=true branch")
        #expect(!isLocalTrueBranch.contains("balanceText("),
                "LOCAL-06: balanceText() must NOT be called inside the isLocal=true branch")
    }

    @Test("Phase 3 invariant preserved: dashboard button SF symbol 'arrow.up.right.square' present")
    func providerRowView_dashboardButtonStillVisibleForLocals() throws {
        let src = try Self.providerRowViewSource()
        let count = src.components(separatedBy: "arrow.up.right.square").count - 1
        #expect(count == 1,
                "ProviderRowView must contain 'arrow.up.right.square' exactly once (Plan 03-07 invariant)")
    }

    @Test("Phase 3 invariant preserved: D-11 degraded subtitle still emits for non-local rows")
    func providerRowView_d11SubtitlePreservedForNonLocals() throws {
        let src = try Self.providerRowViewSource()
        #expect(src.contains("Updated"),
                "ProviderRowView must still contain the 'Updated' text for the D-11 degraded subtitle")
        #expect(src.contains("usage temporarily unavailable"),
                "ProviderRowView must still contain 'usage temporarily unavailable' for D-11 (Plan 03-07)")
    }

    // MARK: - LOCAL-06 source invariants on LocalRowSecondaryView itself

    @Test("LocalRowSecondaryView struct body (pre-#Preview) contains no LOCAL-06 quota/cost surface (LOCAL-06)")
    func localRowSecondaryView_noLocal06References() throws {
        let full = try Self.localRowSecondaryViewSource()
        // Approach A: strip everything from the first `#Preview` marker onward so
        // that nil-placeholder lines inside Preview stubs don't fire as violations.
        // Only the struct body — where `secondaryText` is computed — is scanned.
        let structBody: String
        if let previewCut = full.range(of: "#Preview") {
            structBody = String(full[full.startIndex..<previewCut.lowerBound])
        } else {
            structBody = full
        }
        // Patterns that would indicate quota/cost surface leaking into the view.
        let violations: [(String, String)] = [
            ("QuotaBar(",           "QuotaBar usage"),
            ("tokenText(",          "tokenText helper call"),
            ("usdText(",            "usdText helper call"),
            ("balanceText(",        "balanceText helper call"),
            (".formatted(.currency","currency formatting"),
            ("tokensToday:",        "tokensToday field read/assign in struct body"),
            ("costTodayUSD:",       "costTodayUSD field read/assign in struct body"),
            ("balanceUSD:",         "balanceUSD field read/assign in struct body"),
        ]
        for (pattern, description) in violations {
            #expect(!structBody.contains(pattern),
                    "LOCAL-06: LocalRowSecondaryView struct body must not contain \(description)")
        }
    }

    @Test("LocalRowSecondaryView source has no AppKit imports (pure SwiftUI)")
    func localRowSecondaryView_noAppKitImports() throws {
        let src = try Self.localRowSecondaryViewSource()
        #expect(!src.contains("NSWorkspace"),
                "LocalRowSecondaryView must not import/use NSWorkspace — pure SwiftUI only")
        #expect(!src.contains("NSAlert"),
                "LocalRowSecondaryView must not use NSAlert — pure SwiftUI only")
    }
}

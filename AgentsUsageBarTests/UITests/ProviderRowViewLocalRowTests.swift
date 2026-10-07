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
        #expect(src.contains("isLocalRuntime"),
                "ProviderRowView must key off ProviderID.isLocalRuntime for the isLocal check")
    }

    @Test("Claude account costs use compact caption typography")
    func accountChildCostsUseCaptionFont() throws {
        let src = try Self.providerRowViewSource()
        #expect(src.contains("Text(cost.formatted(.currency(code: \"USD\")))\n                        .font(.caption2)"),
                "AccountChildRow cost must match its compact account label")
    }

    @Test("Claude account children use compact dual-lane glance bars")
    func accountChildrenUseDualLaneBars() throws {
        let src = try Self.providerRowViewSource()
        #expect(src.contains("ClaudeQuotaGlanceView(glance: account.quotaGlance, now: now)"),
                "AccountChildRow must render its own 5h/7d composite glance bar")
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

@Suite("Codex popover children")
struct CodexChildRowTests {
    private let now = Date(timeIntervalSince1970: 1_790_227_200)

    @Test("primary fraction and primary reset win over a higher secondary")
    func primaryWindowSuppliesBarAndReset() {
        let primaryReset = now.addingTimeInterval(2 * 3_600 + 50 * 60)
        let secondaryReset = now.addingTimeInterval(6 * 86_400)
        let account = UsageSnapshot.AccountUsage(
            name: "plus",
            costTodayUSD: Decimal(string: "9.99"),
            quota: Quota(used: 0.90, limit: 1, remaining: 0.10),
            quotaWindows: [
                QuotaWindow(name: "secondary", utilization: 0.90, resetsAt: secondaryReset, duration: 604_800),
                QuotaWindow(name: "primary", utilization: 0.20, resetsAt: primaryReset, duration: 18_000),
            ]
        )

        let content = CodexChildRow.content(for: account, now: now)

        #expect(content.quota?.used == 0.20)
        #expect(content.reset == "Resets 2h 50m")
    }

    @Test("a nil primary reset still has a bar and a dash countdown")
    func nilPrimaryResetUsesDash() {
        let account = UsageSnapshot.AccountUsage(
            name: "team",
            costTodayUSD: nil,
            quota: Quota(used: 0.40, limit: 1, remaining: 0.60),
            quotaWindows: [
                QuotaWindow(name: "primary", utilization: 0.40, resetsAt: nil, duration: 18_000)
            ]
        )

        let content = CodexChildRow.content(for: account, now: now)

        #expect(content.quota?.used == 0.40)
        #expect(content.reset == "Resets —")
    }

    @Test("secondary-only and a missing primary fraction are unavailable")
    func missingPrimaryIsUnavailable() {
        let secondaryOnly = UsageSnapshot.AccountUsage(
            name: "plus",
            costTodayUSD: 1,
            quota: Quota(used: 0.90, limit: 1, remaining: 0.10),
            quotaWindows: [
                QuotaWindow(name: "secondary", utilization: 0.90, resetsAt: now.addingTimeInterval(86_400), duration: 604_800)
            ]
        )
        let nilPrimary = UsageSnapshot.AccountUsage(
            name: "team",
            costTodayUSD: nil,
            quota: nil,
            quotaWindows: [
                QuotaWindow(name: "primary", utilization: nil, resetsAt: now.addingTimeInterval(3_600), duration: 18_000)
            ]
        )
        let empty = UsageSnapshot.AccountUsage(
            name: "guest",
            costTodayUSD: nil,
            quota: nil,
            quotaWindows: nil
        )

        for account in [secondaryOnly, nilPrimary, empty] {
            let content = CodexChildRow.content(for: account, now: now)
            #expect(content.quota == nil)
            #expect(content.reset == nil)
        }
    }

    @Test("header bar input is the max primary while header windows stay nil")
    func headerDisplayedQuotaIsMaxPrimary() {
        let plus = UsageSnapshot.AccountUsage(
            name: "plus",
            costTodayUSD: nil,
            quota: Quota(used: 0.20, limit: 1, remaining: 0.80),
            quotaWindows: [
                QuotaWindow(name: "primary", utilization: 0.20, resetsAt: now.addingTimeInterval(3_600), duration: 18_000),
                QuotaWindow(name: "secondary", utilization: 0.90, resetsAt: now.addingTimeInterval(86_400), duration: 604_800),
            ]
        )
        let team = UsageSnapshot.AccountUsage(
            name: "team",
            costTodayUSD: nil,
            quota: nil,
            quotaWindows: nil
        )
        let snapshot = UsageSnapshot(
            providerID: .codex,
            asOf: now,
            tokensToday: 18_404,
            costTodayUSD: Decimal(string: "0.07"),
            balanceUSD: nil,
            quota: Quota(used: 0.20, limit: 1, remaining: 0.80),
            raw: ["source": "codex-accounts"],
            quotaWindows: nil,
            accounts: [plus, team]
        )

        #expect(snapshot.quotaWindows == nil)
        #expect(snapshot.displayedQuota?.used == 0.20)
        #expect(snapshot.accounts?.count == 2)
    }

    @Test("Codex children branch off the Claude glance and the nil-quota bar")
    func sourceBranchesCodexAwayFromClaudeGlance() throws {
        let src = try ProviderRowViewLocalRowTests.providerRowViewSource()
        #expect(src.contains("AccountChildRow(account: account, providerID: state.id, now: ctx.date)"))
        #expect(src.contains("QuotaBar(quota: state.snapshot?.displayedQuota)"))
        #expect(src.contains("if (state.snapshot?.accounts?.count ?? 0) < 2 {"))
        #expect(src.contains("Text(cost.formatted(.currency(code: \"USD\")))\n                        .font(.caption2)"))
        #expect(src.contains("ClaudeQuotaGlanceView(glance: account.quotaGlance, now: now)"))

        guard let start = src.range(of: "private var codexBody"),
              let end = src.range(of: "private var claudeBody"),
              start.lowerBound < end.lowerBound
        else {
            Issue.record("Codex child body must stay separate from the Claude glance body")
            return
        }
        let codexBranch = String(src[start.lowerBound..<end.lowerBound])
        #expect(codexBranch.contains("QuotaBar(quota: quota)"))
        #expect(codexBranch.contains("Text(\"unavailable\")"))
        #expect(!codexBranch.contains("QuotaBar(quota: nil)"))
        #expect(!codexBranch.contains("no limit"))
        #expect(!codexBranch.contains("cost.formatted"))
        #expect(!codexBranch.contains("ClaudeQuotaGlanceView"))
        #expect(!codexBranch.contains("●"))
    }
}

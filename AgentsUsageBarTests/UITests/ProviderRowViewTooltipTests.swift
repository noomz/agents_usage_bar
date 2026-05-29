import Foundation
import Testing
@testable import AgentsUsageBar

/// Plan 03-07 Task 2 — `ProviderRowView` `.help()` tooltip contract
/// (D-15 / GEMINI-03). Source-grep + behavioural tests prove the
/// provider-name label is annotated with `.help(state.snapshot?.tooltipLabel ?? "")`
/// and that the helper resolves correctly for both present and absent
/// tooltipLabel cases.
@Suite("Plan 03-07 Task 2 — ProviderRowView .help() tooltip")
struct ProviderRowViewTooltipTests {

    // MARK: - Source-grep contract

    @Test("ProviderRowView source contains .help(state.snapshot?.tooltipLabel ?? \"\") on displayName")
    func source_containsHelpOnDisplayName() throws {
        let src = try ProviderRowViewDashboardButtonTests.providerRowViewSource()
        #expect(src.contains(".help(state.snapshot?.tooltipLabel ?? \"\")"),
                "ProviderRowView must annotate the displayName Text with .help(state.snapshot?.tooltipLabel ?? \"\") per D-15")
    }

    // MARK: - .help() argument resolution (mirrors what SwiftUI sees)

    /// Mirrors the .help argument computation so the resolution behaviour is
    /// covered without instantiating SwiftUI views in the test process.
    private func tooltipArgument(for snapshot: UsageSnapshot?) -> String {
        snapshot?.tooltipLabel ?? ""
    }

    @Test("nil snapshot -> tooltip argument is \"\" (SwiftUI suppresses .help when empty)")
    func nilSnapshot_resolvesToEmptyString() {
        let arg = tooltipArgument(for: nil)
        #expect(arg == "",
                "SwiftUI's .help(_:) shows no tooltip when the argument is empty — matches D-15 silent-when-absent semantics")
    }

    @Test("snapshot with nil tooltipLabel -> tooltip argument is \"\"")
    func nilTooltipLabel_resolvesToEmptyString() {
        let snapshot = makeSnapshot(tooltipLabel: nil)
        let arg = tooltipArgument(for: snapshot)
        #expect(arg == "")
    }

    @Test("snapshot with tooltipLabel == \"Free\" -> tooltip argument is \"Free\"")
    func presentTooltipLabel_resolvesVerbatim() {
        let snapshot = makeSnapshot(tooltipLabel: "Free")
        let arg = tooltipArgument(for: snapshot)
        #expect(arg == "Free")
    }

    @Test("snapshot with tooltipLabel == \"plus\" -> tooltip argument is \"plus\" (Codex plan_type)")
    func codexPlanType_resolvesVerbatim() {
        let snapshot = makeSnapshot(tooltipLabel: "plus")
        let arg = tooltipArgument(for: snapshot)
        #expect(arg == "plus")
    }

    // MARK: - Helpers

    private func makeSnapshot(tooltipLabel: String?) -> UsageSnapshot {
        UsageSnapshot(
            providerID: .gemini,
            asOf: Date(timeIntervalSince1970: 1_700_000_000),
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: [:],
            quotaWindows: nil,
            tooltipLabel: tooltipLabel
        )
    }
}

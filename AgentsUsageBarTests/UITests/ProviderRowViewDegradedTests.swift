import Foundation
import Testing
@testable import AgentsUsageBar

/// Plan 03-07 Task 2 — D-11 degraded-state styling contract.
///
/// `ProviderRowView` must detect Gemini's `"usage-temporarily-unavailable"`
/// note (Plan 03-06 / D-11) and react with:
///   - amber StatusDot (via the new `forceAmber:` parameter)
///   - dimmed quota bar + value labels (extends the existing UI-08 stale dim)
///   - "Updated Xm ago — usage temporarily unavailable" subtitle line
///
/// The degraded-tag constant lives in `ThresholdEngine.degradedTag` (Plan 03-08
/// single-source invariant) — the view references the same constant via
/// `GeminiOAuthProvider.degradedNote` OR `ThresholdEngine.degradedTag`. Both
/// resolve to `"usage-temporarily-unavailable"`.
@Suite("Plan 03-07 Task 2 — ProviderRowView degraded styling (D-11)")
struct ProviderRowViewDegradedTests {

    // MARK: - Source-grep contract

    @Test("ProviderRowView source detects D-11 degraded marker via raw[\"note\"]")
    func source_detectsDegradedMarker() throws {
        let src = try ProviderRowViewDashboardButtonTests.providerRowViewSource()
        // D-11 tag detection — either via the literal OR the shared constant.
        let hasLiteralDetect = src.contains("usage-temporarily-unavailable")
        let hasConstantDetect = src.contains("ThresholdEngine.degradedTag")
            || src.contains("GeminiOAuthProvider.degradedNote")
        #expect(hasLiteralDetect || hasConstantDetect,
                "ProviderRowView must reference the D-11 marker (literal or shared constant) to detect the degraded state")
    }

    @Test("ProviderRowView passes forceAmber: isDegraded into StatusDot (amber tinting)")
    func source_passesForceAmberToStatusDot() throws {
        let src = try ProviderRowViewDashboardButtonTests.providerRowViewSource()
        #expect(src.contains("forceAmber: isDegraded"),
                "ProviderRowView must pass forceAmber: isDegraded to StatusDot so the degraded state tints amber (D-11)")
    }

    @Test("ProviderRowView renders 'usage temporarily unavailable' subtitle when degraded")
    func source_rendersDegradedSubtitle() throws {
        let src = try ProviderRowViewDashboardButtonTests.providerRowViewSource()
        #expect(src.contains("— usage temporarily unavailable"),
                "ProviderRowView must include the degraded subtitle text per D-11")
    }

    @Test("StatusDot exposes the forceAmber: Bool init parameter (Plan 03-07 extension)")
    func statusDot_exposesForceAmberParameter() throws {
        let src = try Self.statusDotSource()
        #expect(src.contains("forceAmber"),
                "StatusDot must accept the forceAmber: Bool parameter so ProviderRowView can wire the D-11 amber tint")
    }

    // MARK: - Behavioural assertions

    @Test("isDegraded detector matches when raw[\"note\"] == ThresholdEngine.degradedTag")
    func degradedDetector_matchesExactTag() {
        let snap = makeSnapshot(rawNote: ThresholdEngine.degradedTag)
        let isDegraded = snap.raw["note"] == ThresholdEngine.degradedTag
        #expect(isDegraded, "raw[\"note\"]==ThresholdEngine.degradedTag must be detected as degraded")
        #expect(ThresholdEngine.degradedTag == "usage-temporarily-unavailable",
                "DRY invariant: ThresholdEngine.degradedTag literal stays at the canonical value")
    }

    @Test("isDegraded detector does NOT match for different raw[\"note\"] values")
    func degradedDetector_doesNotMatchOtherNotes() {
        for noise in ["", "stale", "rate-limited", "unauthenticated", "ok"] {
            let snap = makeSnapshot(rawNote: noise)
            let isDegraded = snap.raw["note"] == ThresholdEngine.degradedTag
            #expect(isDegraded == false, "raw[\"note\"]=\"\(noise)\" must NOT trip the degraded detector")
        }
    }

    @Test("isDegraded detector does NOT match when raw has no note")
    func degradedDetector_doesNotMatchAbsentNote() {
        let snap = makeSnapshot(rawNote: nil)
        let isDegraded = snap.raw["note"] == ThresholdEngine.degradedTag
        #expect(isDegraded == false)
    }

    // MARK: - Helpers

    private func makeSnapshot(rawNote: String?) -> UsageSnapshot {
        var raw: [String: String] = [:]
        if let note = rawNote { raw["note"] = note }
        return UsageSnapshot(
            providerID: .gemini,
            asOf: Date(timeIntervalSince1970: 1_700_000_000),
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: raw,
            quotaWindows: nil,
            tooltipLabel: nil
        )
    }

    static func statusDotSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repoRoot
            .appendingPathComponent("AgentsUsageBar")
            .appendingPathComponent("UI")
            .appendingPathComponent("Components")
            .appendingPathComponent("StatusDot.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }
}

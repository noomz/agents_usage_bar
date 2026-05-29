import Testing
import SwiftUI
@testable import AgentsUsageBar

/// Plan 02.07 — UI-03 reconciliation lock.
///
/// REQUIREMENTS UI-03 prescribes the ClaudeBar convention (50% / 20%). Phase 1
/// D-30 / B4 already wired this into `QuotaBar.color(forFraction:)` and the
/// existing `QuotaBarTests` cover all 8 numeric boundary cases.
///
/// These 4 additional tests cite UI-03 by name in their test identifiers so any
/// future regression that flips the convention (e.g. accidentally inverting the
/// fraction semantics) trips a test whose name visibly references "UI-03".
/// The pure color function is verified directly via the existing `internal static`
/// test seam (B4), with no snapshot framework dependency.
@Suite("UI-03 ClaudeBar convention lock (Plan 02.07)")
struct QuotaBarThresholdConventionTests {

    @Test("UI-03 ClaudeBar convention: fraction 0.50 → green (>= 50% used = >= 50% bar)")
    func UI03_claudeBar_convention_green_at_50_percent_remaining() {
        #expect(QuotaBar.color(forFraction: 0.50) == Color.green)
    }

    @Test("UI-03 ClaudeBar convention: fraction 0.49 → yellow (just below 0.50 boundary)")
    func UI03_claudeBar_convention_yellow_just_below_50() {
        #expect(QuotaBar.color(forFraction: 0.49) == Color.yellow)
    }

    @Test("UI-03 ClaudeBar convention: fraction 0.20 → yellow (inclusive yellow lower bound)")
    func UI03_claudeBar_convention_yellow_at_20() {
        #expect(QuotaBar.color(forFraction: 0.20) == Color.yellow)
    }

    @Test("UI-03 ClaudeBar convention: fraction 0.19 → red (just below 0.20 boundary)")
    func UI03_claudeBar_convention_red_just_below_20() {
        #expect(QuotaBar.color(forFraction: 0.19) == Color.red)
    }
}

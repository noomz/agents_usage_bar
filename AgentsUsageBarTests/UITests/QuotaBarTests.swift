import Testing
import SwiftUI
@testable import AgentsUsageBar

/// B4 boundary tests for `QuotaBar.color(forFraction:)`.
///
/// These tests verify the PURE color-selection function (not the SwiftUI view body)
/// using the `internal static` test seam exposed by `QuotaBar`.
///
/// Authoritative thresholds (REQUIREMENTS.md UI-02 / B4):
///   fraction == nil  → Color.gray  ("no limit")
///   fraction < 0.20  → Color.red
///   0.20 ≤ fraction < 0.50 → Color.yellow
///   fraction ≥ 0.50  → Color.green
@Suite("QuotaBar color boundary tests")
struct QuotaBarTests {

    @Test("fraction nil → gray (no-limit account, D-14)")
    func fractionNilIsGray() {
        #expect(QuotaBar.color(forFraction: nil) == Color.gray)
    }

    @Test("fraction 0.0 → red (< 0.20)")
    func fraction0IsRed() {
        #expect(QuotaBar.color(forFraction: 0.0) == Color.red)
    }

    @Test("fraction 0.19 → red (< 0.20 boundary)")
    func fraction019IsRed() {
        #expect(QuotaBar.color(forFraction: 0.19) == Color.red)
    }

    @Test("fraction 0.20 → yellow (inclusive lower boundary)")
    func fraction020IsYellow() {
        #expect(QuotaBar.color(forFraction: 0.20) == Color.yellow)
    }

    @Test("fraction 0.49 → yellow (< 0.50)")
    func fraction049IsYellow() {
        #expect(QuotaBar.color(forFraction: 0.49) == Color.yellow)
    }

    @Test("fraction 0.50 → green (inclusive lower boundary)")
    func fraction050IsGreen() {
        #expect(QuotaBar.color(forFraction: 0.50) == Color.green)
    }

    @Test("fraction 0.99 → green")
    func fraction099IsGreen() {
        #expect(QuotaBar.color(forFraction: 0.99) == Color.green)
    }

    @Test("fraction 1.0 → green (overage clamp upper bound)")
    func fraction10IsGreen() {
        // At 100%+ the bar is still green (bar color only; depletion shown separately)
        #expect(QuotaBar.color(forFraction: 1.0) == Color.green)
    }
}

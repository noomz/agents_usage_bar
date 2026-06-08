import Testing
import Foundation
@testable import AgentsUsageBar

/// W2 boundary tests for `RelativeTimestampLabel.relativeString(from:to:)`.
///
/// Tests the `internal static` pure function directly — no SwiftUI view instantiation needed.
///
/// Phase 1 strategy: use short elapsed-time strings (Xs, Xm, Xh, Xd).
/// Very long elapsed periods (>24h) return days — not absolute date strings.
/// This trade-off is documented in RelativeTimestampLabel.swift.
@MainActor
@Suite("RelativeTimestampLabel boundary tests")
struct RelativeTimestampLabelTests {

    // Fixed reference point
    private let T0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test("0s elapsed → '0s'")
    func elapsed0s() {
        let result = RelativeTimestampLabel.relativeString(from: T0, to: T0)
        #expect(result == "0s")
    }

    @Test("1s elapsed → '1s'")
    func elapsed1s() {
        let result = RelativeTimestampLabel.relativeString(from: T0, to: T0.addingTimeInterval(1))
        #expect(result == "1s")
    }

    @Test("59s → '59s' (below minute boundary)")
    func elapsed59s() {
        let result = RelativeTimestampLabel.relativeString(from: T0, to: T0.addingTimeInterval(59))
        #expect(result == "59s")
    }

    @Test("60s → '1m' (minute boundary)")
    func elapsed60s() {
        let result = RelativeTimestampLabel.relativeString(from: T0, to: T0.addingTimeInterval(60))
        #expect(result == "1m")
    }

    @Test("3599s → '59m'")
    func elapsed3599s() {
        let result = RelativeTimestampLabel.relativeString(from: T0, to: T0.addingTimeInterval(3599))
        #expect(result == "59m")
    }

    @Test("3600s → '1h' (hour boundary)")
    func elapsed3600s() {
        let result = RelativeTimestampLabel.relativeString(from: T0, to: T0.addingTimeInterval(3600))
        #expect(result == "1h")
    }

    @Test("86399s → '23h'")
    func elapsed86399s() {
        let result = RelativeTimestampLabel.relativeString(from: T0, to: T0.addingTimeInterval(86399))
        #expect(result == "23h")
    }

    @Test("86400s → '1d' (day boundary)")
    func elapsed86400s() {
        let result = RelativeTimestampLabel.relativeString(from: T0, to: T0.addingTimeInterval(86400))
        #expect(result == "1d")
    }

    @Test("90000s (>24h) → '1d' (Phase 1 uses days, not absolute date string)")
    func elapsed90000s() {
        // Phase 1 trade-off: very long elapsed periods render as days, not absolute date strings.
        // This keeps the label compact and avoids locale/timezone complexity.
        // Revisit in Phase 2 if user feedback demands absolute timestamps.
        let result = RelativeTimestampLabel.relativeString(from: T0, to: T0.addingTimeInterval(90000))
        #expect(result == "1d")
    }
}

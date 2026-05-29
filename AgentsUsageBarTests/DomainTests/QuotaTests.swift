import Testing
@testable import AgentsUsageBar

@Suite("QuotaTests")
struct QuotaTests {

    @Test("fraction at 50 percent")
    func fractionAt50Percent() {
        let q = Quota(used: 5, limit: 10, remaining: 5)
        #expect(abs(q.fraction - 0.5) < 0.001)
    }

    @Test("fraction clamped at 1.0 when overage")
    func fractionClampedAt1WhenOverage() {
        let q = Quota(used: 12, limit: 10, remaining: 0)
        #expect(q.fraction == 1.0)
    }

    @Test("isOverage when used exceeds limit")
    func isOverageWhenUsedExceedsLimit() {
        let q = Quota(used: 12, limit: 10, remaining: 0)
        #expect(q.isOverage == true)
    }

    @Test("fraction does not crash with zero limit")
    func noLimitGuardWithZeroLimit() {
        // Uses leastNonzeroMagnitude guard — must not divide by zero
        let q = Quota(used: 0, limit: 0, remaining: 0)
        #expect(q.fraction >= 0.0)
        #expect(q.fraction <= 1.0)
    }
}

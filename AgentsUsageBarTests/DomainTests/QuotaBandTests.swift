import Testing
@testable import AgentsUsageBar

@Suite("QuotaBand remaining-fraction boundaries (UI-03)")
struct QuotaBandTests {

    @Test("nil remaining → none (no-limit account, D-14)")
    func nilIsNone() {
        #expect(QuotaBand.fromRemainingFraction(nil) == .none)
    }

    @Test("0.0 remaining → critical")
    func zeroIsCritical() {
        #expect(QuotaBand.fromRemainingFraction(0.0) == .critical)
    }

    @Test("0.19 remaining → critical (below 0.20)")
    func nineteenIsCritical() {
        #expect(QuotaBand.fromRemainingFraction(0.19) == .critical)
    }

    @Test("0.20 remaining → warning (inclusive lower bound)")
    func twentyIsWarning() {
        #expect(QuotaBand.fromRemainingFraction(0.20) == .warning)
    }

    @Test("0.49 remaining → warning")
    func fortyNineIsWarning() {
        #expect(QuotaBand.fromRemainingFraction(0.49) == .warning)
    }

    @Test("0.50 remaining → healthy (inclusive lower bound)")
    func fiftyIsHealthy() {
        #expect(QuotaBand.fromRemainingFraction(0.50) == .healthy)
    }

    @Test("0.99 remaining → healthy")
    func ninetyNineIsHealthy() {
        #expect(QuotaBand.fromRemainingFraction(0.99) == .healthy)
    }

    @Test("1.0 remaining → healthy (clamp upper bound)")
    func oneIsHealthy() {
        #expect(QuotaBand.fromRemainingFraction(1.0) == .healthy)
    }

    @Test("values below 0 clamp into critical")
    func negativeClampsToCritical() {
        #expect(QuotaBand.fromRemainingFraction(-1) == .critical)
    }

    @Test("values above 1 clamp into healthy")
    func overOneClampsToHealthy() {
        #expect(QuotaBand.fromRemainingFraction(1.5) == .healthy)
    }
}

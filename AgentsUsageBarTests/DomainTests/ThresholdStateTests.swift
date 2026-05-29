import Testing
@testable import AgentsUsageBar

@Suite("ThresholdStateTests")
struct ThresholdStateTests {

    @Test("from fraction below 80% is normal", arguments: [0.0, 0.5, 0.79])
    func fromFractionBelow80IsNormal(fraction: Double) {
        #expect(ThresholdState.from(fraction: fraction) == .normal)
    }

    @Test("from fraction at 80% is warning")
    func fromFractionAt80IsWarning() {
        #expect(ThresholdState.from(fraction: 0.80) == .warning)
    }

    @Test("from fraction above 80% but below 95% is warning", arguments: [0.81, 0.90, 0.94])
    func fromFractionBetween80And95IsWarning(fraction: Double) {
        #expect(ThresholdState.from(fraction: fraction) == .warning)
    }

    @Test("from fraction at 95% is critical")
    func fromFractionAt95IsCritical() {
        #expect(ThresholdState.from(fraction: 0.95) == .critical)
    }

    @Test("from fraction above 95% but below 100% is critical", arguments: [0.96, 0.99])
    func fromFractionBetween95And100IsCritical(fraction: Double) {
        #expect(ThresholdState.from(fraction: fraction) == .critical)
    }

    @Test("from fraction at 100% is exceeded")
    func fromFractionAt100IsExceeded() {
        #expect(ThresholdState.from(fraction: 1.0) == .exceeded)
    }

    @Test("from fraction above 100% is exceeded")
    func fromFractionAbove100IsExceeded() {
        #expect(ThresholdState.from(fraction: 1.5) == .exceeded)
    }

    @Test("case ordering matches FSM severity")
    func caseOrderingMatchesFSM() {
        // All four states must be distinct and comparable by severity.
        let all: [ThresholdState] = [.normal, .warning, .critical, .exceeded]
        #expect(all.count == 4)
        #expect(all[0] == .normal)
        #expect(all[1] == .warning)
        #expect(all[2] == .critical)
        #expect(all[3] == .exceeded)
    }
}

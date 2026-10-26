import Testing
import Foundation
@testable import AgentsUsageBar

/// Monthly budget bands (SPEC V41, V66).
@Suite("BudgetEngine")
struct BudgetEngineTests {

    private static let now = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!
    private static let claude = BudgetScope.provider(.claude)

    private func evaluate(
        _ caps: [BudgetScope: Decimal],
        spend: [BudgetScope: Decimal?],
        bands: [BudgetScope: ThresholdBand] = [:]
    ) -> (crossings: [BudgetCrossing], bands: [BudgetScope: ThresholdBand]) {
        BudgetEngine.evaluate(
            budgets: BudgetConfig(caps: caps.mapValues(Money.init)),
            spends: spend.mapValues { SpendTotal(amount: $0) },
            bands: bands,
            warningFraction: 0.8,
            at: Self.now
        )
    }

    @Test("a jump past 100% records the warning and the limit, notified (V41, V66)")
    func jumpRecordsBoth() {
        let result = evaluate([.total: 50], spend: [.total: 60])
        #expect(result.crossings.map(\.event.kind) == [.budgetWarning, .budgetLimit])
        #expect(result.crossings.allSatisfy { $0.event.notified && $0.event.provider == nil && $0.event.window == nil })
        #expect(result.crossings.first?.event.fraction == 1.2)
        #expect(result.bands[.total] == .exceeded)
    }

    @Test("a provider budget's event names the provider (V33)")
    func providerEvent() {
        let result = evaluate([Self.claude: 10], spend: [Self.claude: 8])
        #expect(result.crossings.map(\.event.kind) == [.budgetWarning])
        #expect(result.crossings.first?.event.provider == .claude)
    }

    @Test("staying in a band records nothing (V41)")
    func sameBandNothing() {
        let result = evaluate([.total: 50], spend: [.total: 45], bands: [.total: .warning])
        #expect(result.crossings.isEmpty)
    }

    @Test("a raised cap lets the band fall with no event, so it can fire again (V41, V66)")
    func raisedCapFallsBack() {
        let raised = evaluate([.total: 100], spend: [.total: 60], bands: [.total: .exceeded])
        #expect(raised.crossings.isEmpty)
        #expect(raised.bands[.total] == .normal)
        let again = evaluate([.total: 100], spend: [.total: 85], bands: raised.bands)
        #expect(again.crossings.map(\.event.kind) == [.budgetWarning])
    }

    @Test("a lowered cap fires at once (V41)")
    func loweredCapFires() {
        let result = evaluate([.total: 20], spend: [.total: 30], bands: [.total: .normal])
        #expect(result.crossings.map(\.event.kind) == [.budgetWarning, .budgetLimit])
    }

    @Test("no cap or unknown spend keeps the band (V39, V40)")
    func noCapOrUnknownKeepsBand() {
        let result = evaluate([.total: 50], spend: [.total: nil, Self.claude: 99], bands: [.total: .warning])
        #expect(result.crossings.isEmpty)
        #expect(result.bands == [.total: .warning])
    }

    @Test("bands seed from the month's budget events, highest per budget (V66)")
    func seedFromEvents() {
        func event(_ provider: ProviderID?, _ kind: UsageEventKind) -> UsageEvent {
            UsageEvent(time: Self.now, provider: provider, kind: kind, fraction: 1, notified: true)
        }
        var day = DayFile(date: "2026-10-03", timeZone: "UTC")
        day.events = [event(nil, .budgetLimit), event(nil, .budgetWarning), event(.claude, .budgetWarning),
                      event(.claude, .band80)]
        #expect(BudgetEngine.bands(from: [day]) == [.total: .exceeded, Self.claude: .warning])
    }

    @Test("one notification per budget at its highest crossing, with no snooze action (V66)")
    func decisions() {
        let result = evaluate([.total: 50, Self.claude: 10], spend: [.total: 60, Self.claude: 8])
        let decisions = BudgetEngine.decisions(for: result.crossings, month: "2026-10", displayName: { _ in "Claude" })
        #expect(decisions.map(\.id) == ["budget:total:2026-10:limit", "budget:claude:2026-10:warn"])
        #expect(decisions.map(\.title) == ["Monthly budget reached", "Claude budget at 80%"])
        #expect(decisions.allSatisfy { !$0.snoozable })
        // V58: a budget click opens Overview on This month.
        #expect(decisions.allSatisfy { $0.route == DashboardRoute(range: .thisMonth) })
        #expect(decisions[1].body == "$8.00 of $10.00 spent this month.")
    }
}

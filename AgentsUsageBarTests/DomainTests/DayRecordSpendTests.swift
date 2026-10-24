import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("DayRecord.costSplit")
struct DayRecordSpendTests {

    private func account(_ key: String, _ model: BillingModel, cost: Decimal? = nil) -> DayAccount {
        DayAccount(key: key, label: key, billingModel: model, costUSD: cost.map(Money.init))
    }

    private func record(cost: Decimal?, estimated: Bool = false, _ accounts: [DayAccount]) -> DayRecord {
        DayRecord(provider: ProviderID(rawValue: "demo"), costUSD: cost.map(Money.init),
                  costEstimated: estimated, accounts: accounts, origin: .observed)
    }

    @Test("a metered record's cost is spend (V26)")
    func meteredIsSpend() {
        let split = record(cost: 3, [account("default", .metered)]).costSplit
        #expect(split == DayCostSplit(hasMetered: true, spend: Money(3), hasSubscription: false, value: nil,
                                      estimated: false))
    }

    @Test("a subscription record's cost is value, never spend (V26, ADR 0001)")
    func subscriptionIsValue() {
        let split = record(cost: 5, estimated: true, [account("work-demo", .subscription)]).costSplit
        #expect(split.spend == nil)
        #expect(!split.hasMetered)
        #expect(split.value == Money(5))
        #expect(split.estimated)
    }

    @Test("per-account costs split a mixed record")
    func perAccountSplit() {
        let split = record(cost: 7, [account("a", .metered, cost: 2), account("b", .subscription, cost: 5)]).costSplit
        #expect(split.spend == Money(2))
        #expect(split.value == Money(5))
    }

    @Test("a mixed record without per-account cost is unknown, not guessed (V7, V26)")
    func mixedWithoutSplitIsUnknown() {
        let split = record(cost: 7, [account("a", .metered), account("b", .subscription)]).costSplit
        #expect(split.hasMetered && split.spend == nil)
        #expect(split.hasSubscription && split.value == nil)
    }

    @Test("unknown cost stays unknown, never zero (V7)")
    func unknownCost() {
        let split = record(cost: nil, [account("default", .metered)]).costSplit
        #expect(split.hasMetered)
        #expect(split.spend == nil)
    }

    @Test("a local record has neither spend nor value")
    func local() {
        let split = record(cost: nil, [account("default", .local)]).costSplit
        #expect(!split.hasMetered && !split.hasSubscription)
    }
}

@Suite("SpendTotal.month")
struct MonthSpendTests {

    private func spend(_ id: ProviderID, _ cost: Decimal?, estimated: Bool = false,
                       _ model: BillingModel = .metered) -> DayRecord {
        DayRecord(provider: id, costUSD: cost.map(Money.init), costEstimated: estimated,
                  accounts: [DayAccount(key: "default", label: "default", billingModel: model)],
                  origin: .observed)
    }

    private func day(_ date: String, _ records: DayRecord...) -> DayFile {
        DayFile(date: date, timeZone: "UTC", records: records)
    }

    @Test("sums the month's metered spend, open day included, and ignores the previous month (V40)")
    func sumsMonthOnly() {
        let days = [
            day("2026-09-30", spend(.openrouter, 100)),
            day("2026-10-01", spend(.openrouter, 2)),
            day("2026-10-02", spend(.openrouter, 3)),
            day("2026-10-03", spend(.openrouter, 4)),
        ]
        let total = SpendTotal.month(days, today: "2026-10-03", scope: .provider(.openrouter))
        #expect(total == SpendTotal(amount: 9))
    }

    @Test("a gap or a nil cost adds nothing and marks the month incomplete (V40)")
    func gapAndNilAreIncomplete() {
        let days = [
            day("2026-10-01", spend(.openrouter, 2)),
            day("2026-10-03", spend(.openrouter, nil)),
        ]
        let total = SpendTotal.month(days, today: "2026-10-03", scope: .provider(.openrouter))
        #expect(total == SpendTotal(amount: 2, incomplete: true))
    }

    @Test("estimated metered spend counts and marks the month estimated (V40)")
    func estimatedCounts() {
        let days = [day("2026-10-01", spend(.claude, 4, estimated: true))]
        let total = SpendTotal.month(days, today: "2026-10-01", scope: .provider(.claude))
        #expect(total == SpendTotal(amount: 4, estimated: true))
    }

    @Test("subscription value is never month spend (V26)")
    func subscriptionIsNotSpend() {
        let days = [day("2026-10-01", spend(.claude, 40, estimated: true, .subscription))]
        let total = SpendTotal.month(days, today: "2026-10-01", scope: .provider(.claude))
        #expect(total.amount == nil)
        #expect(!total.incomplete)
    }

    @Test("the total sums cost-reporting providers with metered spend only (V39, V40)")
    func totalSumsCostReporting() {
        let days = [
            day("2026-10-01",
                spend(.openrouter, 2), spend(.claude, 3), spend(.grok, 50),
                spend(.codex, 30, estimated: true, .subscription)),
            day("2026-10-02", spend(.openrouter, 1), spend(.claude, 1)),
        ]
        let total = SpendTotal.month(days, today: "2026-10-02", scope: .total)
        #expect(total == SpendTotal(amount: 7))
    }

    @Test("month keys come from the Gregorian key text, not a calendar (V2)")
    func keysFromText() {
        let days = [day("2026-02-28", spend(.openrouter, 1)), day("2026-03-01", spend(.openrouter, 2))]
        #expect(SpendTotal.month(days, today: "2026-03-01", scope: .total) == SpendTotal(amount: 2))
    }
}

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

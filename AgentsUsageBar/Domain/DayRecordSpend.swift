import Foundation

/// A day record's cost split by billing model (SPEC V26, ADR 0001): spend from metered
/// accounts, API-equivalent value from subscription accounts. The two are never added.
public struct DayCostSplit: Sendable, Equatable {
    /// The record has a metered account. When true, a nil `spend` is unknown, not zero (V7).
    public var hasMetered: Bool
    public var spend: Money?
    /// The record has a subscription account. When true, a nil `value` is unknown.
    public var hasSubscription: Bool
    public var value: Money?
    /// The cost is tokens times the price table (V10).
    public var estimated: Bool
}

extension DayRecord {
    /// Spend and value for this day (V26). Per-account costs split a mixed record. Without
    /// them, the record's cost belongs to its one billing model; a mixed record with no
    /// per-account cost (Codex, V9) cannot be split, so both are unknown rather than guessed.
    public var costSplit: DayCostSplit {
        let metered = accounts.filter { $0.billingModel == .metered }
        let subscription = accounts.filter { $0.billingModel == .subscription }
        return DayCostSplit(
            hasMetered: !metered.isEmpty,
            spend: share(of: metered, others: subscription),
            hasSubscription: !subscription.isEmpty,
            value: share(of: subscription, others: metered),
            estimated: costEstimated
        )
    }

    private func share(of group: [DayAccount], others: [DayAccount]) -> Money? {
        guard !group.isEmpty else { return nil }
        let costs = group.compactMap(\.costUSD)
        if costs.count == group.count {
            return Money(costs.reduce(Decimal(0)) { $0 + $1.amount })
        }
        return others.isEmpty ? costUSD : nil
    }
}

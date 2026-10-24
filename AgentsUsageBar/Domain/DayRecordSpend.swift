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

/// A summed amount: the known part, whether any of it is estimated, and whether any day
/// counted is a gap or an unknown amount (V40, V45). `amount` is nil when nothing is known.
public struct SpendTotal: Sendable, Equatable {
    public var amount: Decimal?
    public var estimated = false
    public var incomplete = false

    public init(amount: Decimal? = nil, estimated: Bool = false, incomplete: Bool = false) {
        self.amount = amount
        self.estimated = estimated
        self.incomplete = incomplete
    }

    /// Sums one amount of `costSplit` over days, one record per day and nil for a gap. Days
    /// where `applies` is false add nothing; a gap or an unknown amount marks it incomplete.
    public static func sum(
        _ records: [DayRecord?],
        _ amount: KeyPath<DayCostSplit, Money?>,
        applies: KeyPath<DayCostSplit, Bool>
    ) -> SpendTotal {
        var result = SpendTotal()
        for record in records {
            guard let split = record?.costSplit else {
                result.incomplete = true
                continue
            }
            guard split[keyPath: applies] else { continue }
            guard let money = split[keyPath: amount] else {
                result.incomplete = true
                continue
            }
            result.add(SpendTotal(amount: money.amount, estimated: split.estimated))
        }
        return result
    }

    public mutating func add(_ other: SpendTotal) {
        if let more = other.amount { amount = (amount ?? 0) + more }
        estimated = estimated || other.estimated
        incomplete = incomplete || other.incomplete
    }

    /// Month spend (V40) for `scope` in the local calendar month of `today`, the open day
    /// included. Month keys come from the day-key text, never a calendar (V2). A provider
    /// sums its metered spend (V26). The total sums the cost-reporting providers that have a
    /// metered account this month.
    public static func month(_ days: [DayFile], today: String, scope: BudgetScope) -> SpendTotal {
        let byKey = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let prefix = String(today.prefix(8))
        let keys = (1...(Int(today.suffix(2)) ?? 1)).map { prefix + String(format: "%02d", $0) }
        func records(_ id: ProviderID) -> [DayRecord?] {
            keys.map { byKey[$0]?.records.first { $0.provider == id } }
        }
        switch scope {
        case .provider(let id):
            return sum(records(id), \.spend, applies: \.hasMetered)
        case .total:
            var total = SpendTotal()
            for id in BudgetScope.providers {
                let days = records(id)
                guard days.contains(where: { $0?.costSplit.hasMetered == true }) else { continue }
                total.add(sum(days, \.spend, applies: \.hasMetered))
            }
            return total
        }
    }
}

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
        guard costs.count == group.count else { return others.isEmpty ? costUSD : nil }
        let sum = Money(costs.reduce(Decimal(0)) { $0 + $1.amount })
        // One billing model: a backfill top-up no account owns stays in the total (V31, V68).
        guard others.isEmpty, let costUSD else { return sum }
        return max(sum, costUSD)
    }

    /// `costSplit` broken into accounts (V68). A lone account of a billing model takes that
    /// model's cost; otherwise an account with its own cost gets it, and what is left is one
    /// unattributed segment. Nothing is prorated (V12). An unknown model total has no segments.
    public var costSegments: [DayCostSegment] {
        let split = costSplit
        return [(BillingModel.metered, split.spend), (.subscription, split.value)].flatMap { model, total in
            guard let total else { return [DayCostSegment]() }
            let group = accounts.filter { $0.billingModel == model }
            if group.count == 1 { return [DayCostSegment(account: group[0].key, billingModel: model, amount: total)] }
            var segments = group.compactMap { account in
                account.costUSD.map { DayCostSegment(account: account.key, billingModel: model, amount: $0) }
            }
            let rest = total.amount - segments.reduce(Decimal(0)) { $0 + $1.amount.amount }
            if rest > 0 { segments.append(DayCostSegment(account: nil, billingModel: model, amount: Money(rest))) }
            return segments
        }
    }
}

extension DayRecord {
    /// `tokens` broken into accounts (V68): a lone account takes the record's tokens;
    /// otherwise each account with its own tokens (V9) gets them, and what is left is one
    /// unattributed segment, so a day recorded before account tokens is all unattributed.
    /// Nothing is prorated (V12). Unknown tokens have no segments.
    public var tokenSegments: [DayTokenSegment] {
        guard let tokens else { return [] }
        if accounts.count == 1 { return [DayTokenSegment(account: accounts[0].key, tokens: tokens)] }
        var segments = accounts.compactMap { account in
            account.tokens.map { DayTokenSegment(account: account.key, tokens: $0) }
        }
        let rest = tokens - segments.reduce(0) { $0 + $1.tokens }
        if rest > 0 { segments.append(DayTokenSegment(account: nil, tokens: rest)) }
        return segments
    }
}

/// One account's part of a day's tokens (V68). A nil account is unattributed.
public struct DayTokenSegment: Sendable, Equatable {
    public var account: String?
    public var tokens: Int
}

/// One account's part of a day's spend or value (V68). A nil account is unattributed.
public struct DayCostSegment: Sendable, Equatable {
    public var account: String?
    /// Metered is spend, subscription is value; the two never stack (V26).
    public var billingModel: BillingModel
    public var amount: Money
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

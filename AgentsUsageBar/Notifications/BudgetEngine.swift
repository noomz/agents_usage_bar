import Foundation

/// One budget crossing on this poll (SPEC V41): the usage event to record, plus the month
/// spend and cap the notification shows.
public struct BudgetCrossing: Sendable, Equatable {
    public let scope: BudgetScope
    public let event: UsageEvent
    public let spend: SpendTotal
    public let cap: Money
}

/// Monthly budget bands (SPEC V41, V66). A budget is `.warning` at the warning threshold and
/// `.exceeded` at 100%. Crossings are upward only; the band follows the current spend, so a
/// raised cap lets it fall and fire again. Budgets have no snooze, so every crossing is
/// notified.
public enum BudgetEngine {

    public static func band(spend: Decimal, cap: Money, warningFraction: Double) -> ThresholdBand {
        let fraction = fraction(spend: spend, cap: cap)
        if fraction >= 1 { return .exceeded }
        if fraction >= warningFraction { return .warning }
        return .normal
    }

    /// Crossings for every capped scope with a known month spend, and the bands after this
    /// poll. A scope with no cap or no known spend keeps its band.
    public static func evaluate(
        budgets: BudgetConfig,
        spends: [BudgetScope: SpendTotal],
        bands: [BudgetScope: ThresholdBand],
        warningFraction: Double,
        at now: Date
    ) -> (crossings: [BudgetCrossing], bands: [BudgetScope: ThresholdBand]) {
        var crossings: [BudgetCrossing] = []
        var next = bands
        for scope in BudgetScope.all {
            guard let cap = budgets.caps[scope], let spend = spends[scope], let amount = spend.amount else { continue }
            let current = band(spend: amount, cap: cap, warningFraction: warningFraction)
            let last = bands[scope] ?? .normal
            for crossed in [ThresholdBand.warning, .exceeded] where crossed > last && crossed <= current {
                let event = UsageEvent(
                    time: now,
                    provider: scope.providerID,
                    kind: crossed == .exceeded ? .budgetLimit : .budgetWarning,
                    fraction: fraction(spend: amount, cap: cap),
                    notified: true
                )
                crossings.append(BudgetCrossing(scope: scope, event: event, spend: spend, cap: cap))
            }
            next[scope] = current
        }
        return (crossings, next)
    }

    /// The highest band each budget reached in these days' events (V66).
    public static func bands(from days: [DayFile]) -> [BudgetScope: ThresholdBand] {
        var bands: [BudgetScope: ThresholdBand] = [:]
        for event in days.flatMap(\.events) {
            let band: ThresholdBand
            switch event.kind {
            case .budgetWarning: band = .warning
            case .budgetLimit: band = .exceeded
            default: continue
            }
            let scope = event.provider.map(BudgetScope.provider) ?? .total
            bands[scope] = max(bands[scope] ?? .normal, band)
        }
        return bands
    }

    /// One notification per budget at its highest crossing this poll, with no snooze action
    /// (V66). `month` is the day key's `yyyy-MM`, so the id stays stable within the month.
    public static func decisions(
        for crossings: [BudgetCrossing],
        month: String,
        displayName: (ProviderID) -> String
    ) -> [NotificationDecision] {
        var highest: [BudgetScope: BudgetCrossing] = [:]
        for crossing in crossings where crossing.event.kind == .budgetLimit || highest[crossing.scope] == nil {
            highest[crossing.scope] = crossing
        }
        return BudgetScope.all.compactMap { scope in
            guard let crossing = highest[scope], let amount = crossing.spend.amount else { return nil }
            let name = scope.providerID.map(displayName) ?? "Monthly"
            let limit = crossing.event.kind == .budgetLimit
            let percent = Int((crossing.event.fraction * 100).rounded(.down))
            let spent = (crossing.spend.estimated ? "~" : "") + usd(amount)
            return NotificationDecision(
                id: "budget:\(scope.name):\(month):\(limit ? "limit" : "warn")",
                title: limit ? "\(name) budget reached" : "\(name) budget at \(percent)%",
                body: "\(spent) of \(usd(crossing.cap.amount)) spent this month.",
                providerID: scope.providerID ?? ProviderID(rawValue: "budget"),
                displayName: name,
                band: limit ? .exceeded : .warning,
                snoozable: false,
                route: DashboardRoute(range: .thisMonth)
            )
        }
    }

    private static func fraction(spend: Decimal, cap: Money) -> Double {
        guard cap.amount > 0 else { return 0 }
        return NSDecimalNumber(decimal: spend / cap.amount).doubleValue
    }

    private static func usd(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: "USD"))
    }
}

extension BudgetScope {
    /// The provider a provider budget caps; nil for the total (V33).
    public var providerID: ProviderID? {
        if case .provider(let id) = self { return id }
        return nil
    }
}

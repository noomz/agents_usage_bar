import Foundation

/// Aggregate token and cost totals across all active providers for today.
///
/// Computed by `AggregateStore` after each poll cycle by summing `UsageSnapshot` values.
public struct DailyTotals: Sendable, Equatable, Codable {
    public var tokens: Int
    public var costUSD: Decimal

    public init(tokens: Int, costUSD: Decimal) {
        self.tokens = tokens
        self.costUSD = costUSD
    }

    /// The zero-value identity element for accumulation.
    public static let zero = DailyTotals(tokens: 0, costUSD: 0)
}

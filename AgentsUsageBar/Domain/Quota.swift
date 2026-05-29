import Foundation

/// Represents a usage quota with used/limit/remaining triple.
///
/// D-14: Accounts without a quota limit set `quota == nil` on `UsageSnapshot`.
/// This type is only instantiated when a limit exists.
public struct Quota: Sendable, Equatable, Codable {
    public let used: Double
    public let limit: Double
    public let remaining: Double

    public init(used: Double, limit: Double, remaining: Double) {
        self.used = used
        self.limit = limit
        self.remaining = remaining
    }

    /// Fraction of quota consumed, clamped to [0.0, 1.0].
    ///
    /// Uses `leastNonzeroMagnitude` in the denominator guard to prevent division-by-zero
    /// when `limit == 0` (RESEARCH.md Open Question 5).
    public var fraction: Double {
        min(1.0, max(0.0, used / max(limit, .leastNonzeroMagnitude)))
    }

    /// `true` when `used > limit` (credit overage / post-limit charges).
    public var isOverage: Bool {
        used > limit
    }
}

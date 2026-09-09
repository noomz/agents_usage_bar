import Foundation

/// A time-bounded quota window for a Claude Max/Pro subscription.
///
/// Sourced from `GET /api/oauth/usage` (CLAUDE-04, RESEARCH §B.2).
/// Separate from `Quota` (which holds an absolute limit/used triple).
/// `QuotaWindow` carries only a utilization percentage (0.0–1.0) and a reset timestamp.
///
/// Open Question 4 (RESEARCH): Anthropic delivers utilization as a 0–100 percentage.
/// Normalisation to 0.0–1.0 happens in Plan 02.04 (ClaudeJSONLProvider) before
/// construction — this type stores the already-normalised value.
///
/// CLAUDE-04: `utilization` may be nil when the server returns a window object
/// without a utilization field (e.g. a new model tier not yet tracked).
/// `resetsAt` may be nil if the API omits it.
public struct QuotaWindow: Sendable, Equatable, Codable {

    /// Human-readable window label, e.g. "5h", "7d", "7d-sonnet", "7d-opus".
    public let name: String

    /// Fraction of quota consumed, normalised to [0.0, 1.0].
    /// The raw API delivers a 0–100 percentage; Plan 02.04 normalises before storing.
    /// `nil` when the API omits the utilization field for this window.
    public let utilization: Double?

    /// UTC timestamp at which this window resets.
    /// `nil` when the API omits the reset time.
    public let resetsAt: Date?

    public init(name: String, utilization: Double?, resetsAt: Date?) {
        self.name = name
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    /// Claude session window (`"5h"` or `"work 5h"`). Weekly is `"7d"` / `"7d-sonnet"`.
    public var isFiveHour: Bool {
        name == "5h" || name.hasSuffix(" 5h")
    }

    /// Utilization as a `Quota` triple (`limit` = 1.0). `nil` when utilization is omitted.
    public var asQuota: Quota? {
        guard let utilization else { return nil }
        return Quota(used: utilization, limit: 1.0, remaining: max(0, 1.0 - utilization))
    }
}

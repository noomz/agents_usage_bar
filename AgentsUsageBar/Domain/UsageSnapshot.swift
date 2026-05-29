import Foundation

/// An immutable snapshot of one provider's usage data as of a single poll cycle.
///
/// Produced by a provider's `fetch(now:)` and stored in `ProviderState.snapshot`.
/// `ProviderRowView` reads fields directly — nil means "not available for this provider".
public struct UsageSnapshot: Sendable, Equatable, Codable {

    /// The provider this snapshot belongs to.
    public let providerID: ProviderID

    /// Timestamp of the poll that produced this snapshot.
    public let asOf: Date

    /// Tokens consumed today, if the provider exposes a token count.
    ///
    /// OpenRouter exposes no per-request token field in `/api/v1/credits` or `/api/v1/key` —
    /// Phase 1 always sets this to `nil`. Future providers (Claude, Codex) will populate it.
    public let tokensToday: Int?

    /// USD cost accumulated today using the baseline-delta approach (D-01).
    /// `nil` on cold launch before the second poll completes (D-03).
    public let costTodayUSD: Decimal?

    /// Account balance: `total_credits − total_usage` (RESEARCH.md Open Question 3, ROUTER-03).
    /// `nil` for providers that do not expose balance.
    public let balanceUSD: Decimal?

    /// Credit quota, if the provider enforces one.
    /// `nil` for no-limit accounts (D-14, ROUTER-03); threshold engine skips these.
    public let quota: Quota?

    /// Raw provider-specific fields for debugging.
    /// Phase 1 always ships `[:]`; Phase 5 Settings exposes this for developer inspection.
    public let raw: [String: String]

    public init(
        providerID: ProviderID,
        asOf: Date,
        tokensToday: Int?,
        costTodayUSD: Decimal?,
        balanceUSD: Decimal?,
        quota: Quota?,
        raw: [String: String]
    ) {
        self.providerID = providerID
        self.asOf = asOf
        self.tokensToday = tokensToday
        self.costTodayUSD = costTodayUSD
        self.balanceUSD = balanceUSD
        self.quota = quota
        self.raw = raw
    }
}

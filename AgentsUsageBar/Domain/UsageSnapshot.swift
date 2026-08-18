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

    /// Time-bounded quota windows from the Anthropic OAuth usage endpoint (CLAUDE-04).
    ///
    /// Populated by `ClaudeOAuthClient.getUsage()` in Plan 02.04. All Phase 1 providers
    /// (OpenRouter) and existing tests omit this parameter — default `nil` preserves
    /// backwards-compat.
    ///
    /// Open Question 4 (RESEARCH): Only Claude Max/Pro accounts expose quota windows;
    /// pay-per-token accounts return an empty or absent `quota_windows` array.
    public let quotaWindows: [QuotaWindow]?

    /// Per-account usage split for providers that aggregate several accounts into one
    /// row (Claude hook mode across ccs instances). `nil` for every other provider and
    /// for single-account feeds; `ProviderRowView` renders one indented child row per
    /// element when ≥2 are present.
    ///
    /// Decoding compatibility: `Optional` + synthesised `init(from:)`, so cache envelopes
    /// written before this field existed decode with `accounts == nil` (same pattern as
    /// `tooltipLabel`).
    public let accounts: [AccountUsage]?

    /// One account's slice of an aggregated provider row.
    public struct AccountUsage: Sendable, Equatable, Codable, Identifiable {
        /// Account key — "default" for `~/.claude`, else the ccs instance slug.
        public let name: String
        /// Today's cost reported by this account's sessions. `nil` = no data today.
        public let costTodayUSD: Decimal?
        /// Max utilization across this account's quota windows (drives the child bar).
        public let quota: Quota?
        /// This account's own quota windows (plain "5h"/"7d" names, with `resetsAt`).
        public let quotaWindows: [QuotaWindow]?

        public var id: String { name }

        public init(name: String, costTodayUSD: Decimal?, quota: Quota?, quotaWindows: [QuotaWindow]?) {
            self.name = name
            self.costTodayUSD = costTodayUSD
            self.quota = quota
            self.quotaWindows = quotaWindows
        }
    }

    /// Optional tooltip surfaced via SwiftUI `.help()` on `ProviderRowView` (D-15).
    ///
    /// Carries Codex `plan_type` (e.g. `"plus"`, `"pro"`, `"team"`, `"enterprise"`)
    /// and the Gemini tier label so the provider-name label can disclose
    /// account-tier context on cursor hover without claiming a dedicated UI
    /// row. `nil` for providers that don't surface a tier (OpenRouter, Claude
    /// today, all Phase 1/2 call sites by default).
    ///
    /// Decoding compatibility: the field is `Decodable` via synthesised
    /// `init(from:)` and is `Optional`, so existing on-disk cache envelopes
    /// written before this field existed continue to decode without error
    /// (the synthesised decoder reads absent optional keys as `nil`).
    public let tooltipLabel: String?

    public init(
        providerID: ProviderID,
        asOf: Date,
        tokensToday: Int?,
        costTodayUSD: Decimal?,
        balanceUSD: Decimal?,
        quota: Quota?,
        raw: [String: String],
        quotaWindows: [QuotaWindow]? = nil,
        tooltipLabel: String? = nil,
        accounts: [AccountUsage]? = nil
    ) {
        self.providerID = providerID
        self.asOf = asOf
        self.tokensToday = tokensToday
        self.costTodayUSD = costTodayUSD
        self.balanceUSD = balanceUSD
        self.quota = quota
        self.raw = raw
        self.quotaWindows = quotaWindows
        self.tooltipLabel = tooltipLabel
        self.accounts = accounts
    }

    /// Secondary-line caption when a provider has quota but no today tokens/cost
    /// (Grok billing, Gemini windows). `nil` keeps the existing "— · —" dashes.
    public var quotaUsageCaption: String? {
        guard tokensToday == nil, costTodayUSD == nil, let quota else { return nil }
        let pct = Int((quota.fraction * 100).rounded())
        if let period = raw["period"], !period.isEmpty {
            return "\(pct)% used · \(period)"
        }
        return "\(pct)% used"
    }
}

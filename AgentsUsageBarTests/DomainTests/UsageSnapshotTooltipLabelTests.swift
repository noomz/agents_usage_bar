import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - UsageSnapshotTooltipLabelTests
//
// Domain extension test for the optional `tooltipLabel: String?` field added in
// Plan 03-04 Task 1 to carry Codex `plan_type` and Gemini tier label per D-15.
//
// Acceptance:
// 1. UsageSnapshot built without the tooltipLabel argument → tooltipLabel == nil
//    (backward-compat default — every Phase 1/2 call site that omits the param
//    must continue to compile and produce a snapshot with tooltipLabel == nil).
// 2. UsageSnapshot built with `tooltipLabel: "plus"` → tooltipLabel == "plus".
// 3. JSON round-trip preserves tooltipLabel.
// 4. Decoding a JSON blob with NO `tooltipLabel` key → tooltipLabel == nil (no
//    DecodingError; the field is optional and must not break existing on-disk
//    cache envelopes).

@Suite("UsageSnapshotTooltipLabelTests")
struct UsageSnapshotTooltipLabelTests {

    // MARK: - 1. Default nil

    @Test func quotaUsageCaption_whenQuotaOnly() {
        let snap = UsageSnapshot(
            providerID: .grok,
            asOf: Date(timeIntervalSince1970: 1_700_000_000),
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: Quota(used: 24, limit: 100, remaining: 76),
            raw: ["period": "weekly"]
        )
        #expect(snap.quotaUsageCaption == "24% used · weekly")
    }

    @Test func quotaUsageCaption_nil_whenTodayCostPresent() {
        let snap = UsageSnapshot(
            providerID: .openrouter,
            asOf: Date(timeIntervalSince1970: 1_700_000_000),
            tokensToday: nil,
            costTodayUSD: Decimal(string: "0.57"),
            balanceUSD: nil,
            quota: Quota(used: 1, limit: 10, remaining: 9),
            raw: [:]
        )
        #expect(snap.quotaUsageCaption == nil)
    }

    @Test func init_withoutTooltipLabel_defaultsToNil() {
        let snap = UsageSnapshot(
            providerID: .codex,
            asOf: Date(timeIntervalSince1970: 1_700_000_000),
            tokensToday: 100,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: [:],
            quotaWindows: nil
        )
        #expect(snap.tooltipLabel == nil)
    }

    // MARK: - 2. Stored verbatim

    @Test func init_withTooltipLabel_storesVerbatim() {
        let snap = UsageSnapshot(
            providerID: .codex,
            asOf: Date(timeIntervalSince1970: 1_700_000_000),
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: [:],
            quotaWindows: nil,
            tooltipLabel: "plus"
        )
        #expect(snap.tooltipLabel == "plus")
    }

    // MARK: - 3. JSON round-trip

    @Test func jsonRoundTrip_preservesTooltipLabel() throws {
        let original = UsageSnapshot(
            providerID: .codex,
            asOf: Date(timeIntervalSince1970: 1_700_000_000),
            tokensToday: 42,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: ["k": "v"],
            quotaWindows: nil,
            tooltipLabel: "pro"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(decoded.tooltipLabel == "pro")
        #expect(decoded == original)
    }

    // MARK: - 4. Backward-compat decode (no tooltipLabel key in payload)

    @Test func decode_jsonWithoutTooltipLabelKey_returnsNil() throws {
        // Round-trip a pre-existing UsageSnapshot (built without tooltipLabel),
        // strip the key from the encoded payload to simulate a cache envelope
        // written by Phase 1/2 builds that pre-date this field, then decode.
        // The synthesised Codable conformance treats optional properties as
        // `decodeIfPresent` semantics, so absent keys MUST decode to `nil`
        // rather than throwing — preserves on-disk backwards-compat.
        let original = UsageSnapshot(
            providerID: .codex,
            asOf: Date(timeIntervalSince1970: 700_000_000),
            tokensToday: 5,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: [:],
            quotaWindows: nil
        )
        let encoded = try JSONEncoder().encode(original)
        var json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        // Hard-strip the tooltipLabel key to simulate pre-field cache file
        json.removeValue(forKey: "tooltipLabel")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: stripped)
        #expect(decoded.tooltipLabel == nil)
        #expect(decoded.tokensToday == 5)
        #expect(decoded.providerID == .codex)
    }
}

// MARK: - Glance bar prefers the 5h session window

/// Live bug 2026-09-09: work 5h was 24% (Claude Code current session) but the
/// child bar showed weekly 68% because `account.quota = max(5h, 7d)` while the
/// reset caption used the soonest window (always 5h).
@Suite("UsageSnapshotDisplayedQuota")
struct UsageSnapshotDisplayedQuotaTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snap(
        quota: Quota?,
        windows: [QuotaWindow]? = nil,
        accounts: [UsageSnapshot.AccountUsage]? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerID: .claude,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: quota,
            raw: [:],
            quotaWindows: windows,
            accounts: accounts
        )
    }

    @Test func accountPrefersFiveHourOverWeekly() {
        let account = UsageSnapshot.AccountUsage(
            name: "work",
            costTodayUSD: Decimal(string: "325.25"),
            quota: Quota(used: 0.68, limit: 1, remaining: 0.32),
            quotaWindows: [
                QuotaWindow(name: "5h", utilization: 0.24, resetsAt: now.addingTimeInterval(4 * 3600 + 11 * 60)),
                QuotaWindow(name: "7d", utilization: 0.68, resetsAt: now.addingTimeInterval(3 * 86400)),
            ]
        )
        #expect(account.quota?.used == 0.68)
        #expect(account.displayedQuota?.used == 0.24)
        #expect(account.displayedResetsAt == now.addingTimeInterval(4 * 3600 + 11 * 60))
    }

    @Test func accountFallsBackToWeeklyWhenFiveHourMissing() {
        let account = UsageSnapshot.AccountUsage(
            name: "personal",
            costTodayUSD: Decimal(string: "0.25"),
            quota: Quota(used: 0.70, limit: 1, remaining: 0.30),
            quotaWindows: [
                QuotaWindow(name: "7d", utilization: 0.70, resetsAt: now.addingTimeInterval(86400)),
            ]
        )
        #expect(account.displayedQuota?.used == 0.70)
        #expect(account.displayedResetsAt == now.addingTimeInterval(86400))
    }

    @Test func parentBarUsesWorstFiveHourAcrossAccounts() {
        let personal = UsageSnapshot.AccountUsage(
            name: "personal",
            costTodayUSD: Decimal(string: "78.15"),
            quota: Quota(used: 0.41, limit: 1, remaining: 0.59),
            quotaWindows: [
                QuotaWindow(name: "5h", utilization: 0.20, resetsAt: now.addingTimeInterval(4 * 3600)),
                QuotaWindow(name: "7d", utilization: 0.41, resetsAt: now.addingTimeInterval(2 * 86400)),
            ]
        )
        let work = UsageSnapshot.AccountUsage(
            name: "work",
            costTodayUSD: Decimal(string: "325.25"),
            quota: Quota(used: 0.68, limit: 1, remaining: 0.32),
            quotaWindows: [
                QuotaWindow(name: "5h", utilization: 0.24, resetsAt: now.addingTimeInterval(4 * 3600)),
                QuotaWindow(name: "7d", utilization: 0.68, resetsAt: now.addingTimeInterval(3 * 86400)),
            ]
        )
        let snapshot = snap(
            quota: Quota(used: 0.68, limit: 1, remaining: 0.32),
            windows: [
                QuotaWindow(name: "personal 5h", utilization: 0.20, resetsAt: now.addingTimeInterval(4 * 3600)),
                QuotaWindow(name: "personal 7d", utilization: 0.41, resetsAt: now.addingTimeInterval(2 * 86400)),
                QuotaWindow(name: "work 5h", utilization: 0.24, resetsAt: now.addingTimeInterval(4 * 3600)),
                QuotaWindow(name: "work 7d", utilization: 0.68, resetsAt: now.addingTimeInterval(3 * 86400)),
            ],
            accounts: [personal, work]
        )
        #expect(snapshot.quota?.used == 0.68)
        #expect(snapshot.displayedQuota?.used == 0.24)
    }

    @Test func jsonlParentPrefersUnprefixedFiveHourWindow() {
        let snapshot = snap(
            quota: Quota(used: 0.62, limit: 1, remaining: 0.38),
            windows: [
                QuotaWindow(name: "5h", utilization: 0.38, resetsAt: now.addingTimeInterval(3 * 3600)),
                QuotaWindow(name: "7d", utilization: 0.62, resetsAt: now.addingTimeInterval(4 * 86400)),
            ]
        )
        #expect(snapshot.displayedQuota?.used == 0.38)
    }

    @Test func nonClaudeWindowsLeaveStoredQuota() {
        let snapshot = snap(
            quota: Quota(used: 0.80, limit: 1, remaining: 0.20),
            windows: [
                QuotaWindow(name: "primary", utilization: 0.80, resetsAt: now),
                QuotaWindow(name: "secondary", utilization: 0.10, resetsAt: now),
            ]
        )
        #expect(snapshot.displayedQuota?.used == 0.80)
    }
}

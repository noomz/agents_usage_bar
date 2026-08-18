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

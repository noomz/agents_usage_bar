import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("ThresholdEngineTests")
struct ThresholdEngineTests {

    // MARK: - Helpers

    /// Calendar pinned to America/Los_Angeles for stable-ID tests.
    static let ptCalendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    /// 2026-05-11 12:00:00 America/Los_Angeles
    static let noon_2026_05_11_PT: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 11
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return ptCalendar.date(from: comps)!
    }()

    static let openrouterID = ProviderID(rawValue: "openrouter")

    func makeSnapshot(
        providerID: ProviderID = openrouterID,
        quota: Quota? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerID: providerID,
            asOf: Date(),
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: quota,
            raw: [:]
        )
    }

    func makeQuota(used: Double, limit: Double) -> Quota {
        Quota(used: used, limit: limit, remaining: limit - used)
    }

    let engine = ThresholdEngine()

    // MARK: - Tests

    @Test("no decision when quota is nil (no-limit account, D-14)")
    func noDecisionWhenQuotaIsNil() {
        let snap = makeSnapshot(quota: nil)
        let result = engine.decisions(for: [snap], now: Date(), snoozedUntil: [:])
        #expect(result.isEmpty)
    }

    @Test("no decision when fraction < warningFraction (default 0.80)")
    func noDecisionBelowThreshold() {
        let snap = makeSnapshot(quota: makeQuota(used: 7.0, limit: 10.0)) // 0.70
        let result = engine.decisions(for: [snap], now: Date(), snoozedUntil: [:])
        #expect(result.isEmpty)
    }

    @Test("decision returned when fraction >= warningFraction")
    func decisionReturnedAtThreshold() {
        let snap = makeSnapshot(quota: makeQuota(used: 8.2, limit: 10.0)) // 0.82
        let result = engine.decisions(for: [snap], now: Date(), snoozedUntil: [:])
        #expect(result.count == 1)
    }

    @Test("stable single-decision ID format: providerID:yyyy-MM-dd:warn80")
    func stableIDFormat() throws {
        let engine = ThresholdEngine(warningFraction: 0.80, calendar: Self.ptCalendar)
        let snap = makeSnapshot(quota: makeQuota(used: 8.2, limit: 10.0))
        let result = engine.decisions(for: [snap], now: Self.noon_2026_05_11_PT, snoozedUntil: [:])
        try #require(result.count == 1)
        #expect(result[0].id == "openrouter:2026-05-11:warn80")
    }

    @Test("single-decision title format includes integer percentage (fraction 0.82 → 'OpenRouter at 82%')")
    func titleFormat() throws {
        let snap = makeSnapshot(quota: makeQuota(used: 8.2, limit: 10.0))
        let result = engine.decisions(for: [snap], now: Date(), snoozedUntil: [:])
        try #require(result.count == 1)
        #expect(result[0].title == "OpenRouter at 82%")
    }

    @Test("single-decision body format includes USD currency (used=8.20, limit=10.00)")
    func bodyFormat() throws {
        let snap = makeSnapshot(quota: makeQuota(used: 8.20, limit: 10.00))
        let result = engine.decisions(for: [snap], now: Date(), snoozedUntil: [:])
        try #require(result.count == 1)
        // Body: "$8.20 of $10.00 used today."
        #expect(result[0].body.contains("8.20"))
        #expect(result[0].body.contains("10.00"))
        #expect(result[0].body.hasSuffix("used today."))
    }

    @Test("decision.displayName populated for coalescing (B3)")
    func displayNamePopulated() throws {
        let snap = makeSnapshot(quota: makeQuota(used: 8.2, limit: 10.0))
        let result = engine.decisions(for: [snap], now: Date(), snoozedUntil: [:])
        try #require(result.count == 1)
        #expect(result[0].displayName == "OpenRouter")
    }

    @Test("snoozedUntil suppresses decision when snooze > now")
    func snoozeSuppresses() {
        let now = Date()
        let snap = makeSnapshot(quota: makeQuota(used: 8.2, limit: 10.0))
        let snoozed: [ProviderID: Date] = [Self.openrouterID: now.addingTimeInterval(3600)]
        let result = engine.decisions(for: [snap], now: now, snoozedUntil: snoozed)
        #expect(result.isEmpty)
    }

    @Test("snoozedUntil does NOT suppress when snooze <= now")
    func snoozeDoesNotSuppressWhenExpired() {
        let now = Date()
        let snap = makeSnapshot(quota: makeQuota(used: 8.2, limit: 10.0))
        let snoozed: [ProviderID: Date] = [Self.openrouterID: now.addingTimeInterval(-1)]
        let result = engine.decisions(for: [snap], now: now, snoozedUntil: snoozed)
        #expect(result.count == 1)
    }

    @Test("currentBand maps fractions correctly")
    func currentBandMapping() {
        #expect(engine.currentBand(for: 0.70) == .normal)
        #expect(engine.currentBand(for: 0.80) == .warning)
        #expect(engine.currentBand(for: 0.95) == .critical)
        #expect(engine.currentBand(for: 1.00) == .exceeded)
    }

    @Test("Phase 1 only emits .warning band decisions (D-11): fraction 0.96 → empty")
    func criticalBandSuppressedInPhase1() {
        let snap = makeSnapshot(quota: makeQuota(used: 9.6, limit: 10.0)) // 0.96 → critical
        let result = engine.decisions(for: [snap], now: Date(), snoozedUntil: [:])
        #expect(result.isEmpty, "Critical band must not emit in Phase 1 (D-11)")
    }

    @Test("multi-snapshot input returns multi-decision list (NOTIF-07 surface; B3)")
    func multiSnapshotReturnsMultiDecision() throws {
        let snap1 = makeSnapshot(
            providerID: ProviderID(rawValue: "openrouter"),
            quota: makeQuota(used: 8.2, limit: 10.0)
        )
        let snap2 = makeSnapshot(
            providerID: ProviderID(rawValue: "claude"),
            quota: makeQuota(used: 8.5, limit: 10.0)
        )
        let result = engine.decisions(for: [snap1, snap2], now: Date(), snoozedUntil: [:])
        #expect(result.count == 2)
        try #require(result.count == 2)
        #expect(result[0].id != result[1].id, "Distinct providers must yield distinct stable IDs")
    }
}

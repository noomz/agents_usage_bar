import Testing
import Foundation
@testable import AgentsUsageBar

/// Plan 02.05 — covers the FSM-aware `decisions(for:now:snoozedUntilDay:lastBands:)`
/// overload plus the `ThresholdBand: Comparable` conformance (NOTIF-01..05).
@Suite("ThresholdEngineFSMTests")
struct ThresholdEngineFSMTests {

    // MARK: - Fixtures

    /// Calendar pinned to America/Los_Angeles so day-string derivation is deterministic
    /// across CI and developer machines (Pitfall 4).
    static let ptCalendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    /// 2026-05-13 12:00:00 America/Los_Angeles — picks a day that yields "2026-05-13".
    static let noon_2026_05_13_PT: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 13
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return ptCalendar.date(from: comps)!
    }()

    static let today = "2026-05-13"
    static let yesterday = "2026-05-12"

    static let pidA = ProviderID(rawValue: "openrouter")
    static let pidB = ProviderID(rawValue: "claude")
    static let pidC = ProviderID(rawValue: "codex")

    let engine = ThresholdEngine(warningFraction: 0.80, calendar: ptCalendar)

    // MARK: - Helpers

    func snap(_ id: ProviderID, fraction: Double) -> UsageSnapshot {
        let limit = 100.0
        let used = fraction * limit
        return UsageSnapshot(
            providerID: id,
            asOf: Self.noon_2026_05_13_PT,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: Quota(used: used, limit: limit, remaining: limit - used),
            raw: [:]
        )
    }

    func snapNoQuota(_ id: ProviderID) -> UsageSnapshot {
        UsageSnapshot(
            providerID: id,
            asOf: Self.noon_2026_05_13_PT,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: [:]
        )
    }

    // MARK: - Comparable conformance

    @Test("ThresholdBand: Comparable orders by rank — normal < warning < critical < exceeded")
    func comparable_band_ordering() {
        #expect(ThresholdBand.normal < ThresholdBand.warning)
        #expect(ThresholdBand.warning < ThresholdBand.critical)
        #expect(ThresholdBand.critical < ThresholdBand.exceeded)
        // Transitive sanity
        #expect(ThresholdBand.normal < ThresholdBand.exceeded)
        // Strictly less — equality is not less-than
        #expect(!(ThresholdBand.warning < ThresholdBand.warning))
    }

    // MARK: - Transition emission

    @Test("normal → warning emits :warn80")
    func transition_normal_to_warning_emits_warn80() throws {
        let s = snap(Self.pidA, fraction: 0.85)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [Self.pidA: .normal]
        )
        try #require(result.count == 1)
        #expect(result[0].band == .warning)
        #expect(result[0].id.hasSuffix(":warn80"))
        #expect(result[0].id == "openrouter:2026-05-13:warn80")
    }

    @Test("warning → critical emits :crit95")
    func transition_warning_to_critical_emits_crit95() throws {
        let s = snap(Self.pidA, fraction: 0.96)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [Self.pidA: .warning]
        )
        try #require(result.count == 1)
        #expect(result[0].band == .critical)
        #expect(result[0].id.hasSuffix(":crit95"))
    }

    @Test("critical → exceeded emits :exceed100")
    func transition_critical_to_exceeded_emits_exceed100() throws {
        let s = snap(Self.pidA, fraction: 1.05)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [Self.pidA: .critical]
        )
        try #require(result.count == 1)
        #expect(result[0].band == .exceeded)
        #expect(result[0].id.hasSuffix(":exceed100"))
    }

    @Test("same band → no emission (NOTIF-02 transition-only)")
    func same_band_no_emit() {
        let s = snap(Self.pidA, fraction: 0.85)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [Self.pidA: .warning]
        )
        #expect(result.isEmpty)
    }

    @Test("downward transition → no emission (NOTIF-02 upward only)")
    func downward_transition_no_emit() {
        let s = snap(Self.pidA, fraction: 0.85)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [Self.pidA: .critical]
        )
        #expect(result.isEmpty)
    }

    @Test("nil quota → no emission (D-14)")
    func nil_quota_no_emit() {
        let s = snapNoQuota(Self.pidA)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [:]
        )
        #expect(result.isEmpty)
    }

    @Test("multi-provider mixed transitions: A normal→warning, B warning→warning, C critical→exceeded → 2 decisions")
    func multi_provider_partial_transition() throws {
        let sA = snap(Self.pidA, fraction: 0.82)
        let sB = snap(Self.pidB, fraction: 0.86)
        let sC = snap(Self.pidC, fraction: 1.10)
        let result = engine.decisions(
            for: [sA, sB, sC],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [
                Self.pidA: .normal,
                Self.pidB: .warning,    // same-band → skip
                Self.pidC: .critical
            ]
        )
        try #require(result.count == 2)
        let pids = Set(result.map(\.providerID))
        #expect(pids == [Self.pidA, Self.pidC])
        #expect(!pids.contains(Self.pidB))
    }

    // MARK: - Snooze gate (NOTIF-05 + default decision #2)

    @Test("snooze today suppresses warning emission")
    func snooze_today_suppresses_warning() {
        let s = snap(Self.pidA, fraction: 0.85)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [Self.pidA: Self.today],
            lastBands: [Self.pidA: .normal]
        )
        #expect(result.isEmpty)
    }

    @Test("snooze today suppresses critical emission (default decision #2 — ALL bands)")
    func snooze_today_suppresses_critical() {
        let s = snap(Self.pidA, fraction: 0.96)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [Self.pidA: Self.today],
            lastBands: [Self.pidA: .warning]
        )
        #expect(result.isEmpty)
    }

    @Test("snooze today suppresses exceeded emission (default decision #2 — ALL bands)")
    func snooze_today_suppresses_exceeded() {
        let s = snap(Self.pidA, fraction: 1.10)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [Self.pidA: Self.today],
            lastBands: [Self.pidA: .critical]
        )
        #expect(result.isEmpty)
    }

    @Test("snooze yesterday does NOT suppress today (rollover behavior)")
    func snooze_yesterday_does_not_suppress_today() throws {
        let s = snap(Self.pidA, fraction: 0.85)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [Self.pidA: Self.yesterday],
            lastBands: [Self.pidA: .normal]
        )
        try #require(result.count == 1)
        #expect(result[0].band == .warning)
    }

    @Test("normal → exceeded jump emits ONE decision at .exceeded, not 3 separate notifications")
    func multiBand_jump_normal_to_exceeded_emits_one_decision_at_exceeded() throws {
        let s = snap(Self.pidA, fraction: 1.05)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [Self.pidA: .normal]
        )
        try #require(result.count == 1)
        #expect(result[0].band == .exceeded)
        #expect(result[0].id.hasSuffix(":exceed100"))
    }

    // MARK: - Phase 1 back-compat surface

    @Test("Phase 1 back-compat: decisions(for:now:snoozedUntil:) still emits warn80 only at 0.85")
    func phase1_back_compat_decisions_method_still_emits_warn80_only() throws {
        let s = snap(Self.pidA, fraction: 0.85)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntil: [:]
        )
        try #require(result.count == 1)
        #expect(result[0].band == .warning)
        #expect(result[0].id.hasSuffix(":warn80"))
    }

    @Test("Phase 1 back-compat: critical band returns empty via OLD method (D-11 preserved)")
    func phase1_back_compat_critical_band_no_emit_old_method() {
        let s = snap(Self.pidA, fraction: 0.96)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntil: [:]
        )
        #expect(result.isEmpty)
    }

    @Test("Phase 1 back-compat: snoozedUntil Date > now still suppresses")
    func phase1_back_compat_snooze_date_suppresses() {
        let s = snap(Self.pidA, fraction: 0.85)
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntil: [Self.pidA: Self.noon_2026_05_13_PT.addingTimeInterval(3600)]
        )
        #expect(result.isEmpty)
    }
}

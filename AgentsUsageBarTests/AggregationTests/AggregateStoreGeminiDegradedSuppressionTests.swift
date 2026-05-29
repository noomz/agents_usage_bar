import Testing
@testable import AgentsUsageBar
import Foundation

// MARK: - AggregateStoreGeminiDegradedSuppressionTests (Plan 03-08 Task 2)
//
// Exercises the D-11 ThresholdEngine suppression rule: any snapshot whose
// `raw["note"]` equals `ThresholdEngine.degradedTag` ("usage-temporarily-
// unavailable") MUST NOT produce a NotificationDecision on this poll.
//
// Cross-poll FSM tracking is unaffected: the lastBand→newBand transition is
// re-applied on the next non-degraded poll. If the user crossed 80% while the
// provider was degraded, the first non-degraded poll above 80% WILL fire.
//
// Placed in AggregationTests because this exercises the engine-store
// integration (D-11 marker → ThresholdEngine filter → no NotificationDecision
// → AggregateStore.fireThresholdNotificationsIfNeeded doesn't dispatch).

@Suite("AggregateStoreGeminiDegradedSuppressionTests")
struct AggregateStoreGeminiDegradedSuppressionTests {

    // MARK: - Fixtures

    /// Calendar pinned to America/Los_Angeles for deterministic day-string math.
    static let ptCalendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    /// 2026-05-13 12:00:00 PT — yields the day-string "2026-05-13".
    static let noon_2026_05_13_PT: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 13
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return ptCalendar.date(from: comps)!
    }()

    static let pidCodex = ProviderID.codex
    static let pidGemini = ProviderID.gemini
    static let pidOther = ProviderID(rawValue: "hypothetical")

    let engine = ThresholdEngine(warningFraction: 0.80, calendar: ptCalendar)

    // MARK: - Helpers

    /// Build a snapshot with a given quota fraction and optional raw["note"].
    func snap(
        id: ProviderID,
        fraction: Double,
        rawNote: String? = nil,
        extraRaw: [String: String] = [:]
    ) -> UsageSnapshot {
        let limit = 100.0
        let used = fraction * limit
        var raw = extraRaw
        if let note = rawNote { raw["note"] = note }
        return UsageSnapshot(
            providerID: id,
            asOf: Self.noon_2026_05_13_PT,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: Quota(used: used, limit: limit, remaining: limit - used),
            raw: raw
        )
    }

    // MARK: - Test 1: Codex warn80 fires; Gemini crit95-with-degraded-tag suppressed

    @Test("codex_warn80_fires_while_gemini_degraded_crit95_suppressed")
    func test_oneCodexEmitWhileGeminiSuppressed() throws {
        let codex = snap(id: Self.pidCodex, fraction: 0.85)
        let gemini = snap(
            id: Self.pidGemini,
            fraction: 0.96,
            rawNote: ThresholdEngine.degradedTag
        )
        let result = engine.decisions(
            for: [codex, gemini],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [Self.pidCodex: .normal, Self.pidGemini: .normal]
        )
        try #require(result.count == 1)
        #expect(result[0].providerID == Self.pidCodex)
        #expect(result[0].band == .warning)
    }

    // MARK: - Test 2: Single degraded Gemini at exceed100 → zero decisions

    @Test("single_degraded_gemini_at_exceed100_emits_zero")
    func test_singleDegradedExceedEmitsZero() {
        let gemini = snap(
            id: Self.pidGemini,
            fraction: 1.05,
            rawNote: ThresholdEngine.degradedTag
        )
        let result = engine.decisions(
            for: [gemini],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [Self.pidGemini: .normal]
        )
        #expect(result.isEmpty)
    }

    // MARK: - Test 3: Cross-poll recovery — suppressed during degraded, fires after

    @Test("crossPoll_recovery_warn80_fires_on_next_nonDegraded_poll")
    func test_crossPollRecovery() throws {
        // Poll 1 — degraded at 0.85; lastBand .normal → suppressed.
        let pollOne = snap(
            id: Self.pidGemini,
            fraction: 0.85,
            rawNote: ThresholdEngine.degradedTag
        )
        let r1 = engine.decisions(
            for: [pollOne],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [Self.pidGemini: .normal]
        )
        #expect(r1.isEmpty)

        // Poll 2 — same fraction (0.85) but NO degraded tag. lastBand still
        // .normal because Poll 1 was suppressed and never updated the FSM.
        // Threshold breach is now detected.
        let pollTwo = snap(id: Self.pidGemini, fraction: 0.85)
        let r2 = engine.decisions(
            for: [pollTwo],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [Self.pidGemini: .normal]
        )
        try #require(r2.count == 1)
        #expect(r2[0].band == .warning)
        #expect(r2[0].providerID == Self.pidGemini)
    }

    // MARK: - Test 4: Hypothetical future provider also tagged degraded → suppressed

    @Test("nonGemini_provider_with_degradedTag_is_also_suppressed")
    func test_filterIsProviderAgnostic() {
        let s = snap(
            id: Self.pidOther,
            fraction: 0.90,
            rawNote: ThresholdEngine.degradedTag
        )
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [Self.pidOther: .normal]
        )
        #expect(result.isEmpty)
    }

    // MARK: - Test 5: Different note string → NOT suppressed (exact-match only)

    @Test("different_note_string_does_not_suppress")
    func test_differentNoteStringDoesNotSuppress() throws {
        let s = snap(
            id: Self.pidGemini,
            fraction: 0.85,
            rawNote: "some-other-tag"  // NOT degradedTag
        )
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [Self.pidGemini: .normal]
        )
        try #require(result.count == 1)
        #expect(result[0].band == .warning)
    }

    // MARK: - Test 6: Empty raw dict → NOT suppressed (no false positives)

    @Test("empty_raw_dict_does_not_suppress")
    func test_emptyRawDoesNotSuppress() throws {
        let s = snap(id: Self.pidCodex, fraction: 0.85)  // empty raw
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntilDay: [:],
            lastBands: [Self.pidCodex: .normal]
        )
        try #require(result.count == 1)
        #expect(result[0].band == .warning)
    }

    // MARK: - Test 7: Phase 1 back-compat overload ALSO honors the filter

    @Test("phase1_backcompat_overload_honors_degraded_filter")
    func test_phase1BackcompatHonorsFilter() {
        let s = snap(
            id: Self.pidGemini,
            fraction: 0.85,
            rawNote: ThresholdEngine.degradedTag
        )
        let result = engine.decisions(
            for: [s],
            now: Self.noon_2026_05_13_PT,
            snoozedUntil: [:]
        )
        #expect(result.isEmpty)
    }

    // MARK: - Test 8: Degraded tag constant matches GeminiOAuthProvider.degradedNote

    @Test("degradedTag_matches_GeminiOAuthProvider_degradedNote")
    func test_degradedTagConstantsAreEqual() {
        // Plan 03-08 DRY invariant — ThresholdEngine.degradedTag and
        // GeminiOAuthProvider.degradedNote MUST be the same literal so the
        // engine's filter and the provider's stamp agree.
        #expect(ThresholdEngine.degradedTag == GeminiOAuthProvider.degradedNote)
        #expect(ThresholdEngine.degradedTag == "usage-temporarily-unavailable")
    }
}

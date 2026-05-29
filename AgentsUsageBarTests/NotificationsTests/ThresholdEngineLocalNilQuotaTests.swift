import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - ThresholdEngineLocalNilQuotaTests (Plan 04-08 Task 3)
//
// Regression lock: ThresholdEngine.decisions must return [] for any snapshot
// whose quota == nil. Local providers (Ollama, LM Studio, llama.cpp) always
// produce quota: nil snapshots (LOCAL-06 anti-feature), so they must never
// trigger a threshold notification.
//
// This test suite locks the nil-quota guard at ThresholdEngine.swift:124
// (`guard let quota = snap.quota else { return nil }`) against future regressions.

@Suite("ThresholdEngineLocalNilQuotaTests")
struct ThresholdEngineLocalNilQuotaTests {

    let engine = ThresholdEngine()
    let now = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Helpers

    func makeLocalSnapshot(providerID: ProviderID) -> UsageSnapshot {
        UsageSnapshot(
            providerID: providerID,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: ["source": providerID.rawValue]
        )
    }

    func makeRemoteSnapshot(providerID: ProviderID, fraction: Double) -> UsageSnapshot {
        let limit = 10.0
        let used = limit * fraction
        return UsageSnapshot(
            providerID: providerID,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: Quota(used: used, limit: limit, remaining: limit - used),
            raw: [:]
        )
    }

    // MARK: - Test 1: single local snapshot → no decisions

    @Test("localSnapshotWithNilQuota_yieldsNoDecisions")
    func localSnapshotWithNilQuota_yieldsNoDecisions() {
        let localSnap = makeLocalSnapshot(providerID: .ollama)
        let result = engine.decisions(
            for: [localSnap],
            now: now,
            snoozedUntilDay: [:],
            lastBands: [:]
        )
        #expect(result.isEmpty)
    }

    // MARK: - Test 2: mixed local + remote — only remote produces decisions

    @Test("mixedLocalAndRemoteSnapshots_onlyRemoteHasDecisions")
    func mixedLocalAndRemoteSnapshots_onlyRemoteHasDecisions() {
        let localSnap = makeLocalSnapshot(providerID: .ollama)
        let remoteSnap = makeRemoteSnapshot(providerID: .openrouter, fraction: 0.85)

        let result = engine.decisions(
            for: [localSnap, remoteSnap],
            now: now,
            snoozedUntilDay: [:],
            lastBands: [:]
        )
        #expect(result.count == 1)
        #expect(result[0].providerID == .openrouter)
    }

    // MARK: - Test 3: all three local IDs skip the notification gate

    @Test("allThreeLocalIDs_skipNotificationGate")
    func allThreeLocalIDs_skipNotificationGate() {
        let snapshots = [
            makeLocalSnapshot(providerID: .ollama),
            makeLocalSnapshot(providerID: .lmstudio),
            makeLocalSnapshot(providerID: .llamacpp)
        ]
        let result = engine.decisions(
            for: snapshots,
            now: now,
            snoozedUntilDay: [:],
            lastBands: [:]
        )
        #expect(result.isEmpty)
    }

    // MARK: - Test 4: Phase 1 back-compat overload also skips locals

    @Test("phase1BackCompatOverload_alsoSkipsLocals")
    func phase1BackCompatOverload_alsoSkipsLocals() {
        let snapshots = [
            makeLocalSnapshot(providerID: .ollama),
            makeLocalSnapshot(providerID: .lmstudio),
            makeLocalSnapshot(providerID: .llamacpp)
        ]
        let result = engine.decisions(
            for: snapshots,
            now: now,
            snoozedUntil: [:]
        )
        #expect(result.isEmpty)
    }

    // MARK: - Test 5: local with non-nil quota (defensive — would fire if fraction crosses)

    /// Defensive regression guard: ThresholdEngine filters on `quota == nil`, NOT on
    /// `capabilities.isLocal`. If a future local provider somehow stamps a non-nil quota
    /// with fraction >= 0.80, the engine WOULD emit a decision — the quota-nil is the
    /// load-bearing signal, not the isLocal flag.
    @Test("localSnapshotWithQuotaSomehow_doesFireDecisionIfFractionCrosses")
    func localSnapshotWithQuotaSomehow_doesFireDecisionIfFractionCrosses() {
        // Construct a synthetic "local" snapshot that incorrectly carries a quota.
        let syntheticQuota = Quota(used: 8.5, limit: 10.0, remaining: 1.5)
        let unexpectedSnap = UsageSnapshot(
            providerID: .ollama,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: syntheticQuota,  // non-nil — would violate LOCAL-06 in production
            raw: ["source": "ollama"]
        )
        let result = engine.decisions(
            for: [unexpectedSnap],
            now: now,
            snoozedUntilDay: [:],
            lastBands: [:]
        )
        // The engine fires for ANY snapshot with quota.fraction >= warningFraction,
        // regardless of providerID. This is intentional — quota-nil is the gate.
        #expect(result.count == 1,
            "ThresholdEngine filters on quota==nil, not isLocal; a non-nil quota at 0.85 must fire")
    }
}

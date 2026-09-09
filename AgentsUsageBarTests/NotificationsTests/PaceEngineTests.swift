import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("PaceEngineTests")
struct PaceEngineTests {

    static let ptCalendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    /// 2026-09-09 12:00:00 PT
    static let now: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 9
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return ptCalendar.date(from: comps)!
    }()

    let engine = PaceEngine(calendar: ptCalendar)

    func snapshot(
        id: ProviderID = .claude,
        windows: [QuotaWindow],
        raw: [String: String] = [:]
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerID: id,
            asOf: Self.now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: raw,
            quotaWindows: windows
        )
    }

    func window(
        _ name: String,
        used: Double,
        remaining: TimeInterval,
        now: Date = now
    ) -> QuotaWindow {
        QuotaWindow(name: name, utilization: used, resetsAt: now.addingTimeInterval(remaining))
    }

    func evaluate(
        snaps: [UsageSnapshot],
        previous: [PaceSample] = [],
        snoozed: [ProviderID: String] = [:],
        fired: [ProviderID: Set<String>] = [:],
        enabled: Bool = true,
        now: Date = now
    ) -> [NotificationDecision] {
        engine.decisions(
            for: snaps,
            now: now,
            previous: previous,
            snoozedUntilDay: snoozed,
            alreadyFired: fired,
            enabled: enabled
        ).decisions
    }

    // MARK: - Duration parsing

    @Test("duration: 5h, work 5h, 5hr, primary")
    func duration_fiveHourAliases() {
        #expect(PaceWindowDuration.seconds(forName: "5h") == 5 * 3600.0)
        #expect(PaceWindowDuration.seconds(forName: "work 5h") == 5 * 3600.0)
        #expect(PaceWindowDuration.seconds(forName: "5hr") == 5 * 3600.0)
        #expect(PaceWindowDuration.seconds(forName: "primary") == 5 * 3600.0)
    }

    @Test("duration: 7d, 7d-sonnet, secondary, weekly")
    func duration_sevenDayAliases() {
        #expect(PaceWindowDuration.seconds(forName: "7d") == 7 * 86400.0)
        #expect(PaceWindowDuration.seconds(forName: "7d-sonnet") == 7 * 86400.0)
        #expect(PaceWindowDuration.seconds(forName: "secondary") == 7 * 86400.0)
        #expect(PaceWindowDuration.seconds(forName: "weekly") == 7 * 86400.0)
    }

    @Test("duration: gemini model ids and billing do not parse as hours")
    func duration_unknownNames() {
        #expect(PaceWindowDuration.seconds(forName: "gemini-2.5-pro") == nil)
        #expect(PaceWindowDuration.seconds(forName: "billing") == nil)
        #expect(PaceWindowDuration.seconds(forName: "") == nil)
    }

    // MARK: - A window pace

    @Test("A: 40% used with 4h left in 5h window fires")
    func windowPace_overBudget_fires() {
        // 1h elapsed of 5h, 40% used → on pace to cap in 1.5h, reset in 4h.
        let snap = snapshot(windows: [window("5h", used: 0.40, remaining: 4 * 3600)])
        let result = evaluate(snaps: [snap])
        #expect(result.count == 1)
        #expect(result[0].id == "claude:2026-09-09:pace:5h")
        #expect(result[0].windowName == "5h")
        #expect(result[0].title.contains("5h"))
        #expect(result[0].body.contains("runs out"))
    }

    @Test("A: exactly linear 20%/hour of 5h does not fire")
    func windowPace_onBudget_silent() {
        let snap = snapshot(windows: [window("5h", used: 0.20, remaining: 4 * 3600)])
        #expect(evaluate(snaps: [snap]).isEmpty)
    }

    @Test("A: 40% in first 2 minutes is ignored (elapsed floor)")
    func windowPace_tooEarly_silent() {
        let snap = snapshot(windows: [window("5h", used: 0.40, remaining: 5 * 3600 - 120)])
        #expect(evaluate(snaps: [snap]).isEmpty)
    }

    @Test("A: Codex primary uses 5h length")
    func windowPace_codexPrimary() {
        let snap = snapshot(
            id: .codex,
            windows: [window("primary", used: 0.50, remaining: 3 * 3600)]
        )
        let result = evaluate(snaps: [snap])
        #expect(result.count == 1)
        #expect(result[0].id == "codex:2026-09-09:pace:primary")
    }

    @Test("A: unknown-length window (Gemini model) does not fire from A alone")
    func windowPace_unknownLength_noA() {
        let snap = snapshot(
            id: .gemini,
            windows: [window("gemini-2.5-pro", used: 0.80, remaining: 3600)]
        )
        #expect(evaluate(snaps: [snap]).isEmpty)
    }

    // MARK: - B recent stream

    @Test("B: 8% jump in 90s with hours remaining fires even without known length")
    func recentStream_spike_fires() {
        let prev = PaceSample(
            providerID: .gemini,
            windowName: "gemini-2.5-pro",
            utilization: 0.20,
            asOf: Self.now.addingTimeInterval(-90)
        )
        let snap = snapshot(
            id: .gemini,
            windows: [window("gemini-2.5-pro", used: 0.28, remaining: 4 * 3600)]
        )
        let result = evaluate(snaps: [snap], previous: [prev])
        #expect(result.count == 1)
        #expect(result[0].id.contains(":pace:gemini-2.5-pro"))
        #expect(result[0].providerID == .gemini)
    }

    @Test("B: 2% jitter is below the 3% floor")
    func recentStream_jitter_silent() {
        let prev = PaceSample(
            providerID: .gemini,
            windowName: "gemini-2.5-pro",
            utilization: 0.20,
            asOf: Self.now.addingTimeInterval(-90)
        )
        // Unknown-length window: A cannot fire. Δu=0.02 is below the 3% B floor.
        let snap = snapshot(
            id: .gemini,
            windows: [window("gemini-2.5-pro", used: 0.22, remaining: 4 * 3600)]
        )
        #expect(evaluate(snaps: [snap], previous: [prev]).isEmpty)
    }

    @Test("B: Grok billing window uses recent stream")
    func recentStream_grokBilling() {
        let prev = PaceSample(
            providerID: .grok,
            windowName: "billing",
            utilization: 0.50,
            asOf: Self.now.addingTimeInterval(-120)
        )
        let snap = snapshot(
            id: .grok,
            windows: [window("billing", used: 0.60, remaining: 2 * 3600)]
        )
        let result = evaluate(snaps: [snap], previous: [prev])
        #expect(result.count == 1)
        #expect(result[0].providerID == .grok)
    }

    // MARK: - Gates

    @Test("toggle off suppresses decisions but still returns next samples")
    func toggleOff_noDecisions_keepsSamples() {
        let snap = snapshot(windows: [window("5h", used: 0.40, remaining: 4 * 3600)])
        let result = engine.decisions(
            for: [snap],
            now: Self.now,
            previous: [],
            snoozedUntilDay: [:],
            alreadyFired: [:],
            enabled: false
        )
        #expect(result.decisions.isEmpty)
        #expect(result.nextSamples.count == 1)
        #expect(result.nextSamples[0].utilization == 0.40)
    }

    @Test("snoozed provider is silent")
    func snoozed_silent() {
        let snap = snapshot(windows: [window("5h", used: 0.40, remaining: 4 * 3600)])
        let today = TodayHelper.formatYYYYMMDD(Self.now, calendar: Self.ptCalendar)
        #expect(evaluate(snaps: [snap], snoozed: [.claude: today]).isEmpty)
    }

    @Test("already-fired window is silent; other window can still fire")
    func alreadyFired_perWindow() {
        let snap = snapshot(windows: [
            window("5h", used: 0.40, remaining: 4 * 3600),
            window("7d", used: 0.50, remaining: 5.5 * 86_400.0)
        ])
        let result = evaluate(snaps: [snap], fired: [.claude: ["5h"]])
        #expect(result.count == 1)
        #expect(result[0].windowName == "7d")
    }

    @Test("degraded snapshots are skipped")
    func degraded_silent() {
        let snap = snapshot(
            windows: [window("5h", used: 0.40, remaining: 4 * 3600)],
            raw: ["note": ThresholdEngine.degradedTag]
        )
        #expect(evaluate(snaps: [snap]).isEmpty)
    }

    @Test("already at 100% does not emit a pace warning")
    func fullyUsed_silent() {
        let snap = snapshot(windows: [window("5h", used: 1.0, remaining: 3600)])
        #expect(evaluate(snaps: [snap]).isEmpty)
    }

    @Test("A and B together emit one decision per window")
    func aAndB_singleDecision() {
        let prev = PaceSample(
            providerID: .claude,
            windowName: "5h",
            utilization: 0.30,
            asOf: Self.now.addingTimeInterval(-90)
        )
        let snap = snapshot(windows: [window("5h", used: 0.40, remaining: 4 * 3600)])
        #expect(evaluate(snaps: [snap], previous: [prev]).count == 1)
    }

    @Test("compactDuration formats minutes, hours, days")
    func compactDuration_units() {
        #expect(PaceEngine.compactDuration(25 * 60) == "25m")
        #expect(PaceEngine.compactDuration(3 * 3600) == "3h")
        #expect(PaceEngine.compactDuration(2 * 86400) == "2d")
        #expect(PaceEngine.compactDuration(30) == "<1m")
    }
}

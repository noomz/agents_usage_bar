import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("ResetEngineTests")
struct ResetEngineTests {

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

    let engine = ResetEngine(calendar: ptCalendar)

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

    func sample(
        id: ProviderID = .claude,
        name: String = "5h",
        used: Double,
        remaining: TimeInterval,
        now: Date = now
    ) -> ResetSample {
        ResetSample(
            providerID: id,
            windowName: name,
            utilization: used,
            resetsAt: now.addingTimeInterval(remaining)
        )
    }

    func evaluate(
        snaps: [UsageSnapshot],
        previous: [ResetSample] = [],
        fired: [ProviderID: Set<String>] = [:],
        warningFraction: Double = 0.80,
        enabled: Bool = true,
        now: Date = now
    ) -> [NotificationDecision] {
        engine.decisions(
            for: snaps,
            now: now,
            previous: previous,
            alreadyFired: fired,
            warningFraction: warningFraction,
            enabled: enabled
        ).decisions
    }

    // MARK: - Fire

    @Test("first poll with no previous sample is silent and keeps next samples")
    func firstPoll_silent_keepsSamples() {
        let snap = snapshot(windows: [window("5h", used: 0.90, remaining: 3600)])
        let result = engine.decisions(
            for: [snap],
            now: Self.now,
            previous: [],
            alreadyFired: [:],
            warningFraction: 0.80,
            enabled: true
        )
        #expect(result.decisions.isEmpty)
        #expect(result.nextSamples.count == 1)
        #expect(result.nextSamples[0].utilization == 0.90)
    }

    @Test("previous 85% then new resetsAt fires")
    func constrainedThenReset_fires() {
        let oldReset = Self.now.addingTimeInterval(60)
        let prev = ResetSample(
            providerID: .claude,
            windowName: "5h",
            utilization: 0.85,
            resetsAt: oldReset
        )
        let snap = snapshot(windows: [window("5h", used: 0.10, remaining: 5 * 3600)])
        let result = evaluate(snaps: [snap], previous: [prev])
        #expect(result.count == 1)
        #expect(result[0].id.hasPrefix("claude:2026-09-09:reset:5h:"))
        #expect(result[0].windowName == "5h")
        #expect(result[0].title == "Claude 5h limit reset")
        #expect(result[0].body == "Usage is available again.")
    }

    @Test("previous 100% then reset fires")
    func exhaustedThenReset_fires() {
        let prev = sample(used: 1.0, remaining: 30)
        let snap = snapshot(windows: [window("5h", used: 0.0, remaining: 5 * 3600)])
        #expect(evaluate(snaps: [snap], previous: [prev]).count == 1)
    }

    @Test("previous 40% (below warning) then reset is silent")
    func idleWindow_silent() {
        let prev = sample(used: 0.40, remaining: 60)
        let snap = snapshot(windows: [window("5h", used: 0.02, remaining: 5 * 3600)])
        #expect(evaluate(snaps: [snap], previous: [prev]).isEmpty)
    }

    @Test("same resetsAt does not fire")
    func sameWindow_silent() {
        let prev = sample(used: 0.90, remaining: 3600)
        let snap = snapshot(windows: [window("5h", used: 0.91, remaining: 3600)])
        #expect(evaluate(snaps: [snap], previous: [prev]).isEmpty)
    }

    @Test("warningFraction 0.95: 80% previous is silent, 96% fires")
    func customThreshold() {
        let prev80 = sample(used: 0.80, remaining: 60)
        let prev96 = sample(used: 0.96, remaining: 60)
        let snap = snapshot(windows: [window("5h", used: 0.05, remaining: 5 * 3600)])
        #expect(evaluate(snaps: [snap], previous: [prev80], warningFraction: 0.95).isEmpty)
        #expect(evaluate(snaps: [snap], previous: [prev96], warningFraction: 0.95).count == 1)
    }

    @Test("Codex primary and Gemini model names fire")
    func otherProviders() {
        let prevCodex = sample(id: .codex, name: "primary", used: 0.90, remaining: 60)
        let snapCodex = snapshot(id: .codex, windows: [window("primary", used: 0.10, remaining: 5 * 3600)])
        let codex = evaluate(snaps: [snapCodex], previous: [prevCodex])
        #expect(codex.count == 1)
        #expect(codex[0].id.contains(":reset:primary:"))

        let prevGemini = sample(id: .gemini, name: "gemini-2.5-pro", used: 0.88, remaining: 60)
        let snapGemini = snapshot(
            id: .gemini,
            windows: [window("gemini-2.5-pro", used: 0.01, remaining: 3600)]
        )
        let gemini = evaluate(snaps: [snapGemini], previous: [prevGemini])
        #expect(gemini.count == 1)
        #expect(gemini[0].id.contains(":reset:gemini-2.5-pro:"))
        #expect(gemini[0].title.contains("gemini-2.5-pro"))
    }

    // MARK: - Gates

    @Test("toggle off suppresses decisions but still returns next samples")
    func toggleOff_noDecisions_keepsSamples() {
        let prev = sample(used: 0.90, remaining: 60)
        let snap = snapshot(windows: [window("5h", used: 0.10, remaining: 5 * 3600)])
        let result = engine.decisions(
            for: [snap],
            now: Self.now,
            previous: [prev],
            alreadyFired: [:],
            warningFraction: 0.80,
            enabled: false
        )
        #expect(result.decisions.isEmpty)
        #expect(result.nextSamples.count == 1)
    }

    @Test("already-fired key is silent; other window can still fire")
    func alreadyFired_perWindow() {
        let prev5h = sample(name: "5h", used: 0.90, remaining: 60)
        let prev7d = sample(name: "7d", used: 0.85, remaining: 86400)
        let snap = snapshot(windows: [
            window("5h", used: 0.10, remaining: 5 * 3600),
            window("7d", used: 0.10, remaining: 7 * 86400)
        ])
        let key = ResetEngine.fireKey(windowName: "5h", resetsAt: prev5h.resetsAt)
        let result = evaluate(
            snaps: [snap],
            previous: [prev5h, prev7d],
            fired: [.claude: [key]]
        )
        #expect(result.count == 1)
        #expect(result[0].windowName == "7d")
    }

    @Test("degraded snapshots are skipped")
    func degraded_silent() {
        let prev = sample(used: 0.90, remaining: 60)
        let snap = snapshot(
            windows: [window("5h", used: 0.10, remaining: 5 * 3600)],
            raw: ["note": ThresholdEngine.degradedTag]
        )
        #expect(evaluate(snaps: [snap], previous: [prev]).isEmpty)
    }

    @Test("window missing utilization or resetsAt is skipped")
    func incompleteWindow_silent() {
        let prev = sample(used: 0.90, remaining: 60)
        let noUtil = snapshot(windows: [
            QuotaWindow(name: "5h", utilization: nil, resetsAt: Self.now.addingTimeInterval(5 * 3600))
        ])
        let noReset = snapshot(windows: [
            QuotaWindow(name: "5h", utilization: 0.10, resetsAt: nil)
        ])
        #expect(evaluate(snaps: [noUtil], previous: [prev]).isEmpty)
        #expect(evaluate(snaps: [noReset], previous: [prev]).isEmpty)
    }

    @Test("current resetsAt earlier than previous is silent")
    func backwardsTimestamp_silent() {
        let prev = sample(used: 0.90, remaining: 5 * 3600)
        let snap = snapshot(windows: [window("5h", used: 0.10, remaining: 60)])
        #expect(evaluate(snaps: [snap], previous: [prev]).isEmpty)
    }
}

import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("QuotaGlance")
struct QuotaGlanceTests {
    private let early = Date(timeIntervalSince1970: 1_700_000_000)
    private let late = Date(timeIntervalSince1970: 1_700_100_000)

    @Test("selects higher raw utilization, not rounded display percentage")
    func selectsRawActiveConstraint() {
        let glance = QuotaGlance(windows: [
            .init(period: .fiveHours, utilization: 0.504, resetsAt: late),
            .init(period: .sevenDays, utilization: 0.505, resetsAt: early),
        ])
        #expect(glance.percent(for: .fiveHours) == "50%")
        #expect(glance.percent(for: .sevenDays) == "51%")
        #expect(glance.active?.period == .sevenDays)
    }

    @Test("exact raw tie selects sooner reset")
    func exactTieUsesSoonerReset() {
        let glance = QuotaGlance(windows: [
            .init(period: .fiveHours, utilization: 0.5, resetsAt: late),
            .init(period: .sevenDays, utilization: 0.5, resetsAt: early),
        ])
        #expect(glance.active?.period == .sevenDays)
        #expect(glance.active?.resetsAt == early)
    }

    @Test("secondary weekly model windows excluded")
    func ignoresSecondaryWeeklyWindows() {
        let glance = QuotaGlance(quotaWindows: [
            .init(name: "5h", utilization: 0.2, resetsAt: early),
            .init(name: "7d", utilization: 0.4, resetsAt: late),
            .init(name: "7d-opus", utilization: 0.9, resetsAt: early),
        ])
        #expect(glance.sevenDays?.utilization == 0.4)
        #expect(glance.active?.period == .sevenDays)
    }

    @Test("aggregate uses highest window per period and preserves account identity")
    func aggregateSelection() {
        let snapshot = UsageSnapshot(
            providerID: .claude, asOf: early, tokensToday: nil, costTodayUSD: nil,
            balanceUSD: nil, quota: nil, raw: [:], accounts: [
                .init(name: "personal", costTodayUSD: nil, quota: nil, quotaWindows: [
                    .init(name: "5h", utilization: 0.7, resetsAt: late),
                    .init(name: "7d", utilization: 0.2, resetsAt: late),
                ]),
                .init(name: "work", costTodayUSD: nil, quota: nil, quotaWindows: [
                    .init(name: "5h", utilization: 0.3, resetsAt: early),
                    .init(name: "7d", utilization: 0.8, resetsAt: early),
                ]),
            ]
        )
        #expect(snapshot.quotaGlance.fiveHours?.accountName == "personal")
        #expect(snapshot.quotaGlance.active?.accountName == "work")
        #expect(snapshot.quotaGlance.active?.period == .sevenDays)
    }

    @Test("missing windows are unavailable")
    func missingWindows() {
        let glance = QuotaGlance(windows: [])
        #expect(glance.hasAnyWindow == false)
        #expect(glance.hasBothWindows == false)
        #expect(glance.percent(for: .fiveHours) == "—")
        #expect(glance.active == nil)
    }
}

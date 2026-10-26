import Foundation
import Testing
@testable import AgentsUsageBar

/// SPEC V26, V54, V56 — provider detail.
@Suite("DashboardProviderDetail")
struct DashboardProviderDetailTests {
    private static let today = "2026-10-25"
    private static let days = SyntheticHistory.days(endingAt: today, count: 40)
    private static let range = DashboardRange.thisMonth.statsRange(today: today)

    private func detail(
        _ id: ProviderID, account: String? = nil, days: [DayFile] = Self.days
    ) -> DashboardProviderDetail {
        DashboardProviderDetail(id: id, days: days, range: Self.range, account: account)
    }

    private func record(_ id: ProviderID, _ key: String, in days: [DayFile] = Self.days) -> DayRecord? {
        days.first { $0.date == key }?.records.first { $0.provider == id }
    }

    @Test("the first tab is named by billing model; local runtimes show presence (V54, V56)")
    func tabTitles() {
        #expect(detail(.openrouter).costTabTitle == "Spend")
        #expect(detail(.claude).costTabTitle == "Value")
        #expect(detail(.codex).costTabTitle == "Spend & value")
        #expect(detail(.ollama).costTabTitle == "Presence")
        #expect(detail(.ollama).costPoints.isEmpty)
    }

    @Test("a mixed provider draws spend and value as two series with separate totals (V26, V54)")
    func mixedNeverSummed() {
        let day = DayFile(date: Self.today, timeZone: "UTC", records: [DayRecord(
            provider: .codex, tokens: 1_000, costUSD: Money(5), costEstimated: true,
            accounts: [
                DayAccount(key: "m", label: "m", billingModel: .metered, costUSD: Money(2)),
                DayAccount(key: "s", label: "s", billingModel: .subscription, plan: "plus", costUSD: Money(3)),
            ],
            origin: .observed)])
        let mixed = detail(.codex, days: [day])
        #expect(mixed.stats.spend.amount == 2)
        #expect(mixed.stats.value.amount == 3)
        #expect(mixed.costPoints.map(\.series) == [.spend, .value])
        #expect(mixed.costPoints.map(\.amount) == [2, 3])
        #expect(mixed.costPoints.allSatisfy { $0.estimated })
    }

    @Test("a mixed record without per-account cost has unknown spend and value, never split (V9, V26)")
    func mixedWithoutAccountCost() {
        let codex = detail(.codex)
        #expect(codex.costPoints.isEmpty)
        #expect(codex.stats.spend.amount == nil)
        #expect(codex.stats.spend.incomplete)
    }

    @Test("the account picker narrows cost, quota, and tokens to one account (V54)")
    func narrowToAccount() {
        let all = detail(.claude)
        let work = detail(.claude, account: "work-demo")
        #expect(work.account == "work-demo")
        #expect(all.accounts.map(\.key) == ["work-demo", "default"])
        #expect(work.shownAccounts.map(\.key) == ["work-demo"])
        // Claude reports cost per account; the record's own cost is the sum.
        let accountSum = Self.range.keys.compactMap { key in
            record(.claude, key)?.accounts.first { $0.key == "work-demo" }?.costUSD?.amount
        }.reduce(Decimal(0), +)
        #expect(work.stats.value.amount == accountSum)
        #expect(work.stats.value.amount != all.stats.value.amount)
        // Only the 5h window is on the account.
        #expect(all.quotaWindows == ["5h", "7d"])
        #expect(work.quotaWindows == ["5h"])
        // Two accounts on the record: tokens are not per account.
        #expect(work.tokenPoints.isEmpty)
        #expect(work.tokens.total == nil)
        #expect(all.tokens.total != nil)
    }

    @Test("narrowing a mixed provider to its metered account leaves spend unknown (V9)")
    func narrowMixedToMetered() {
        let metered = detail(.codex, account: "a1b2c3d4e5f6")
        #expect(metered.stats.kind == .metered)
        #expect(metered.costTabTitle == "Spend")
        #expect(metered.stats.spend.amount == nil)
        #expect(metered.stats.spend.incomplete)
    }

    @Test("a record's only account keeps the record's totals")
    func singleAccount() {
        let all = detail(.openrouter)
        let only = detail(.openrouter, account: "default")
        #expect(only.stats.spend == all.stats.spend)
        #expect(only.tokens.total == all.tokens.total)
        #expect(only.costPoints == all.costPoints)
    }

    @Test("an account not seen in range is dropped, and views show the newest label (V22)")
    func accountsAndLabels() {
        var days = Self.days
        let last = days.count - 1
        let index = days[last].records.firstIndex { $0.provider == .codex }!
        days[last].records[index].accounts[1].label = "plus-renamed"
        let codex = detail(.codex, account: "missing", days: days)
        #expect(codex.account == nil)
        #expect(codex.accounts.first { $0.key == "f6e5d4c3b2a1" }?.label == "plus-renamed")
    }

    @Test("a missing record is a no-data band; a recorded day without quota is not (V56, V64)")
    func gapsAndNoValue() {
        let claudeGaps = Self.range.keys.filter { record(.claude, $0) == nil }
        #expect(!claudeGaps.isEmpty)
        #expect(detail(.claude).gapKeys == claudeGaps)

        let codex = detail(.codex)
        let backfilled = Self.range.keys.filter { record(.codex, $0)?.origin == .backfilled }
        #expect(!backfilled.isEmpty)
        #expect(codex.gapKeys.isEmpty)
        #expect(Set(codex.quotaBars("5h").map(\.key)).isDisjoint(with: backfilled))
        #expect(codex.quotaBars("5h").count == Self.range.keys.count - backfilled.count)
    }

    @Test("quota bars run from end of day to the peak (V54)")
    func quotaBars() {
        let key = Self.range.keys.first { record(.claude, $0) != nil }!
        let quota = record(.claude, key)!.quota["5h"]!
        let bar = detail(.claude).quotaBars("5h").first { $0.key == key }!
        #expect(bar.peak == quota.peak)
        #expect(bar.endOfDay == quota.endOfDay)
    }

    @Test("events are the provider's in range, newest first; an account keeps provider-level events (V54)")
    func events() {
        var days = Self.days
        let last = days.count - 1
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        days[last].events += [
            UsageEvent(time: base, provider: .claude, kind: .band95, window: "5h", account: "default",
                       fraction: 0.95, notified: false),
            UsageEvent(time: base.addingTimeInterval(60), provider: .claude, kind: .band95, window: "5h",
                       account: "work-demo", fraction: 0.95, notified: true),
            UsageEvent(time: base, provider: .openrouter, kind: .authLost, fraction: 0, notified: true),
        ]
        let all = detail(.claude, days: days)
        #expect(all.events.allSatisfy { $0.provider == .claude })
        #expect(all.events.map(\.time) == all.events.map(\.time).sorted(by: >))
        let monthEvents = days.filter { Self.range.keys.contains($0.date) }.flatMap(\.events)
        #expect(all.events.count == monthEvents.count { $0.provider == .claude })

        let work = detail(.claude, account: "work-demo", days: days)
        #expect(!work.events.contains { $0.account == "default" })
        #expect(work.events.contains { $0.account == "work-demo" })
        #expect(work.events.contains { $0.account == nil })
    }

    private func claudeDay(_ key: String, origin: RecordOrigin = .observed, work: Decimal?, personal: Decimal?, cost: Decimal) -> DayFile {
        DayFile(date: key, timeZone: "UTC", records: [DayRecord(
            provider: .claude, tokens: 1_000, costUSD: Money(cost), costEstimated: true,
            accounts: [
                DayAccount(key: "work-demo", label: "work-demo", billingModel: .subscription, costUSD: work.map(Money.init),
                           quota: ["5h": QuotaDay(peak: 0.9, endOfDay: 0.2)]),
                DayAccount(key: "default", label: "default", billingModel: .subscription, costUSD: personal.map(Money.init),
                           quota: ["5h": QuotaDay(peak: 0.4, endOfDay: 0.1)]),
            ],
            origin: origin)])
    }

    @Test("split stacks value by account, backfilled days unattributed; tokens stay whole (V54, V62, V68)")
    func splitCost() {
        let days = [
            claudeDay("2026-10-24", origin: .backfilled, work: nil, personal: nil, cost: 9),
            claudeDay(Self.today, work: 5, personal: 2, cost: 7),
        ]
        let split = DashboardProviderDetail(id: .claude, days: days, range: Self.range, split: true)
        #expect(split.split)
        let points = split.costPoints
        #expect(points.map(\.part) == [.unattributed, .account("work-demo"), .account("default")])
        #expect(points.map(\.amount) == [9, 5, 2])
        #expect(points.allSatisfy { $0.series == .value })
        #expect(points.first?.backfilled == true)
        #expect(split.label(.account("work-demo")) == "work-demo")
        #expect(split.tokenPoints.count == 2)
        // Split totals match All: nothing is lost or prorated.
        let all = DashboardProviderDetail(id: .claude, days: days, range: Self.range)
        #expect(all.costPoints.map(\.amount).reduce(0, +) == points.map(\.amount).reduce(0, +))
        #expect(all.costPoints.allSatisfy { $0.part == .whole })
    }

    @Test("split draws one quota bar per account per day (V54, V68)")
    func splitQuota() {
        let days = [claudeDay(Self.today, work: 5, personal: 2, cost: 7)]
        let split = DashboardProviderDetail(id: .claude, days: days, range: Self.range, split: true)
        let bars = split.quotaBars("5h")
        #expect(bars.map(\.account) == ["work-demo", "default"])
        #expect(bars.map(\.peak) == [0.9, 0.4])
    }

    @Test("split needs every account shown and more than one seen (V68)")
    func splitOnlyWithSeveralAccounts() {
        #expect(!detail(.claude, account: "work-demo").split)
        #expect(!DashboardProviderDetail(id: .claude, days: Self.days, range: Self.range, account: "work-demo", split: true).split)
        let lone = [DayFile(date: Self.today, timeZone: "UTC", records: [DayRecord(
            provider: .codex, costUSD: Money(4),
            accounts: [DayAccount(key: "a1b2c3d4e5f6", label: "plus", billingModel: .metered)], origin: .observed)])]
        let codex = DashboardProviderDetail(id: .codex, days: lone, range: Self.range, split: true)
        #expect(!codex.split)
        #expect(codex.costPoints.map(\.part) == [.whole])
    }
}

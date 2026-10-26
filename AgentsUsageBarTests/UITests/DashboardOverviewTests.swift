import Foundation
import Testing
@testable import AgentsUsageBar

/// SPEC V20, V26, V52, V53, V56 — the dashboard sidebar, shared range, and Overview.
@Suite("DashboardOverview")
struct DashboardOverviewTests {
    private static let today = "2026-10-25"
    /// Starts in September so This month has a whole month of history behind it.
    private static let days = SyntheticHistory.days(endingAt: today, count: 40)

    private func overview(
        _ days: [DayFile] = Self.days, range: DashboardRange = .thisMonth, excluded: Set<ProviderID> = []
    ) -> DashboardOverview {
        DashboardOverview(days: days, range: range.statsRange(today: Self.today), excluded: excluded)
    }

    private func only(_ ids: Set<ProviderID>, in days: [DayFile] = Self.days) -> [DayFile] {
        days.map { day in
            var day = day
            day.records = day.records.filter { ids.contains($0.provider) }
            day.events = day.events.filter { $0.provider.map(ids.contains) ?? true }
            return day
        }
    }

    @Test("ranges end today; This month starts on the 1st from the key text (V52)")
    func ranges() {
        let week = DashboardRange.days7.statsRange(today: Self.today)
        #expect(week.keys.first == "2026-10-19")
        #expect(week.keys.last == Self.today)
        #expect(DashboardRange.days90.statsRange(today: Self.today).keys.count == 90)
        let month = DashboardRange.thisMonth.statsRange(today: Self.today)
        #expect(month.keys.first == "2026-10-01")
        #expect(month.keys.count == 25)
        #expect(DashboardRange.thisMonth.statsRange(today: "2026-11-01").keys == ["2026-11-01"])
    }

    @Test("This month with every chip on: Spend equals month spend and budgets (V53)")
    func spendMatchesMonthSpend() {
        let spend = overview().spend
        #expect(spend == SpendTotal.month(Self.days, today: Self.today, scope: .total))
    }

    @Test("value is never added to spend (V26)")
    func valueApartFromSpend() {
        let summary = overview()
        let openRouter = SpendTotal.month(Self.days, today: Self.today, scope: .provider(.openrouter))
        // Codex is mixed with no per-account cost: its spend is unknown, so incomplete.
        #expect(summary.spend.amount == openRouter.amount)
        #expect(summary.spend.incomplete)
        let claudeOnly = overview(only([.claude]))
        #expect(summary.value?.amount == claudeOnly.value?.amount)
        #expect(summary.value?.amount != nil)
    }

    @Test("no metered account: no spend providers, spend chart collapses (V53)")
    func noMetered() {
        let summary = overview(only([.claude]))
        #expect(summary.spendProviders.isEmpty)
        #expect(summary.spend.amount == nil)
        #expect(summary.spendPerDay.isEmpty)
        #expect(summary.value != nil)
    }

    @Test("no subscription account hides the value tile (V53)")
    func noSubscription() {
        #expect(overview(only([.openrouter])).value == nil)
    }

    @Test("chips filter providers and their events; total-budget events stay (V53)")
    func chips() {
        var days = Self.days
        days[days.count - 1].events.append(UsageEvent(
            time: Date(timeIntervalSince1970: 1_793_000_000), provider: nil, kind: .budgetWarning,
            fraction: 0.8, notified: true))
        let summary = overview(days, excluded: [.claude, .openrouter])
        #expect(summary.providers.map(\.id) == [.codex])
        #expect(summary.spendProviders.map(\.id) == [.codex])
        #expect(summary.events.allSatisfy { $0.provider == nil })
        #expect(summary.events.count == 1)
    }

    @Test("usage events count the not-notified ones")
    func notNotified() {
        var days = Self.days
        let time = Date(timeIntervalSince1970: 1_793_000_000)
        days[days.count - 1].events = [
            UsageEvent(time: time, provider: .claude, kind: .band80, window: "5h", fraction: 0.8, notified: false),
            UsageEvent(time: time, provider: .claude, kind: .band95, window: "5h", fraction: 0.95, notified: true),
        ]
        let summary = overview(only([.claude], in: days), range: .days7)
        // Synthetic band events are all notified.
        #expect(summary.notNotifiedCount == 1)
    }

    @Test("local runtimes are left out of Overview and listed under No cost data (V52, V56)")
    func localRuntimes() {
        #expect(!overview().providers.contains { $0.id == .ollama })
        let sidebar = DashboardSidebar(days: Self.days, today: Self.today)
        #expect(sidebar.providers.map(\.id) == [.openrouter, .claude, .codex])
        #expect(sidebar.localRuntimes.map(\.id) == [.ollama])
        #expect(sidebar.localRuntimes[0].trend(bucketSize: 1).allSatisfy { $0 == .present })
    }

    @Test("sidebar mini chart follows the stats trend rule over 14 days (V43, V52)")
    func miniChart() {
        let sidebar = DashboardSidebar(days: Self.days, today: Self.today)
        let range = DashboardRange.days14.statsRange(today: Self.today)
        let stats = ProviderStats.collect(Self.days, range: range, includeLocal: false)
        for provider in sidebar.providers {
            let expected = stats.first { $0.id == provider.id }!
            #expect(provider.records.count == DashboardSidebar.miniChartDays)
            #expect(provider.trend(bucketSize: 1) == expected.trend(bucketSize: 1))
        }
    }

    @Test("quota strip: band per day's peak, gap without a record, no value without the window (V53, V56, V64)")
    func quotaStrip() {
        let summary = overview(range: .days14)
        let claude = summary.quotaRows.first { $0.provider == .claude && $0.window == "5h" }!
        let records = summary.providers.first { $0.id == .claude }!.records
        for (cell, record) in zip(claude.cells, records) {
            if let record {
                #expect(cell == .band(DashboardQuotaCell.band(peak: record.quota["5h"]!.peak)))
            } else {
                #expect(cell == .gap)
            }
        }
        let codex = summary.quotaRows.first { $0.provider == .codex }!
        let codexRecords = summary.providers.first { $0.id == .codex }!.records
        for (cell, record) in zip(codex.cells, codexRecords) where record?.origin == .backfilled {
            #expect(cell == .noValue)
        }
        #expect(codex.cells.contains(.noValue))
        #expect(DashboardQuotaCell.band(peak: 0.79) == .normal)
        #expect(DashboardQuotaCell.band(peak: 0.8) == .warning)
        #expect(DashboardQuotaCell.band(peak: 0.95) == .critical)
        #expect(DashboardQuotaCell.band(peak: 1.0) == .exceeded)
    }

    /// Codex: two metered accounts today (one reports cost), one account yesterday. Claude:
    /// two subscription accounts today, each with a 5h window.
    private static let splitDays: [DayFile] = [
        DayFile(date: "2026-10-24", timeZone: "UTC", records: [
            DayRecord(provider: .codex, tokens: 100, costUSD: Money(4),
                      accounts: [DayAccount(key: "a1", label: "plus", billingModel: .metered)], origin: .observed),
        ]),
        DayFile(date: today, timeZone: "UTC", records: [
            DayRecord(provider: .codex, tokens: 200, costUSD: Money(5), accounts: [
                DayAccount(key: "a1", label: "pro", billingModel: .metered, costUSD: Money(3)),
                DayAccount(key: "b2", label: "team", billingModel: .metered),
            ], origin: .observed),
            DayRecord(provider: .claude, tokens: 300, costUSD: Money(7), costEstimated: true, accounts: [
                DayAccount(key: "work-demo", label: "work-demo", billingModel: .subscription,
                           quota: ["5h": QuotaDay(peak: 0.9, endOfDay: 0.2)]),
                DayAccount(key: "default", label: "default", billingModel: .subscription,
                           quota: ["5h": QuotaDay(peak: 0.4, endOfDay: 0.1)]),
            ], origin: .observed),
        ]),
    ]

    @Test("split accounts stacks metered spend by account, rest unattributed, totals unchanged (V26, V53, V68)")
    func splitSpend() {
        let range = DashboardRange.days7.statsRange(today: Self.today)
        let whole = DashboardOverview(days: Self.splitDays, range: range)
        #expect(whole.splitAccounts.isEmpty)
        #expect(whole.spendPerDay.allSatisfy { $0.part == .whole })

        let split = DashboardOverview(days: Self.splitDays, range: range, split: true)
        let codex = split.spendPerDay.filter { $0.provider == .codex }
        #expect(codex.map(\.key) == ["2026-10-24", Self.today, Self.today])
        #expect(codex.map(\.part) == [.account("a1"), .account("a1"), .unattributed])
        #expect(codex.map(\.amount) == [4, 3, 2])
        // Claude is subscription only: value never enters spend per day (V26).
        #expect(!split.spendPerDay.contains { $0.provider == .claude })
        #expect(split.spendPerDay.map(\.amount).reduce(0, +) == whole.spendPerDay.map(\.amount).reduce(0, +))
        #expect(split.spend == whole.spend)
        // Series are named by the newest account label (V22).
        #expect(split.seriesName(.codex, .account("a1")) == "Codex · pro")
        #expect(split.seriesName(.codex, .unattributed) == "Codex · unattributed")
        // Tokens split too; accounts without their own tokens leave one unattributed part
        // per provider day, and the totals match (V68).
        #expect(split.tokensPerDay.filter { $0.provider == .claude }.map(\.part) == [.unattributed])
        #expect(split.tokensPerDay.map(\.amount).reduce(0, +) == whole.tokensPerDay.map(\.amount).reduce(0, +))
    }

    @Test("split accounts: one quota row per account window, gap when the account was not seen (V53, V68)")
    func splitQuotaStrip() {
        let range = DashboardRange.days7.statsRange(today: Self.today)
        let split = DashboardOverview(days: Self.splitDays, range: range, split: true)
        let claude = split.quotaRows.filter { $0.provider == .claude }
        #expect(claude.map(\.account?.label) == ["work-demo", "default"])
        #expect(claude.map(\.window) == ["5h", "5h"])
        #expect(claude.map { $0.cells.last } == [.band(.warning), .band(.normal)])
        #expect(claude.allSatisfy { $0.cells.dropLast().allSatisfy { $0 == .gap } })
        let whole = DashboardOverview(days: Self.splitDays, range: range)
        #expect(whole.quotaRows.allSatisfy { $0.account == nil })
    }

    @Test("a spend provider without a record is a no-data band; estimated bars are marked (V56)")
    func spendMarkers() {
        var days = Self.days
        days[days.count - 2].records.removeAll { $0.provider == .openrouter }
        let summary = overview(only([.openrouter], in: days), range: .days7)
        #expect(summary.spendGapKeys == [days[days.count - 2].date])
        #expect(summary.spend.incomplete)
        #expect(summary.spendPerDay.count == 6)
        #expect(summary.spendPerDay.allSatisfy { !$0.estimated })
    }

    @Test("budgets: every capped scope, total first, month spend (V40, V53)")
    func budgets() {
        let config = BudgetConfig(caps: [.provider(.openrouter): Money(50), .total: Money(100)])
        let budgets = DashboardBudget.all(days: Self.days, today: Self.today, budgets: config)
        #expect(budgets.map(\.scope) == [.total, .provider(.openrouter)])
        #expect(budgets[1].spend == SpendTotal.month(Self.days, today: Self.today, scope: .provider(.openrouter)))
    }

    @Test("the model reads every day on open and only the open day after a poll (V20)")
    @MainActor
    func reloadsOnlyOpenDay() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dashboard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let days = SyntheticHistory.days(endingAt: Self.today, count: 3)
        try SyntheticHistory.write(days, to: directory)
        let noon = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
        let dayKeys = DayKeyOwner(clock: VirtualClock(fixed: noon), timeZone: TimeZone(identifier: "UTC")!)
        let model = DashboardModel(
            route: DashboardRoute(), reader: HistoryReader(directory: directory), dayKeys: dayKeys, order: [])
        await model.load()
        #expect(model.days.map(\.date) == days.map(\.date))

        var older = days[0]
        older.records = []
        try older.encoded().write(to: directory.appending(path: "\(older.date).json"))
        var open = days[2]
        open.records = []
        try open.encoded().write(to: directory.appending(path: "\(open.date).json"))
        await model.reloadOpenDay()
        #expect(model.days.first { $0.date == older.date }?.records == days[0].records)
        #expect(model.days.first { $0.date == Self.today }?.records == [])
    }

    @Test("routes select the section")
    @MainActor
    func routeSelectsSection() {
        let model = DashboardModel(
            route: DashboardRoute(provider: .codex), reader: HistoryReader(directory: URL(filePath: "/nonexistent")),
            dayKeys: DayKeyOwner(), order: [])
        #expect(model.section == .provider(.codex))
        model.show(DashboardRoute(day: "2026-10-01"))
        #expect(model.section == .calendar)
        model.show(DashboardRoute())
        #expect(model.section == .overview)
    }

    @Test("a route's range sets the shared range; a day route outlines and highlights (V58)")
    @MainActor
    func routeRangeAndFocus() throws {
        let model = DashboardModel(
            route: DashboardRoute(range: .thisMonth), reader: HistoryReader(directory: URL(filePath: "/nonexistent")),
            dayKeys: DayKeyOwner(), order: [])
        #expect(model.section == .overview)
        #expect(model.range == .thisMonth)
        #expect(model.focus == nil)

        model.show(DashboardRoute(day: "2026-10-01", provider: .claude, event: .pace, window: "5h"))
        #expect(model.range == .thisMonth)
        let focus = try #require(model.focus)
        let at = Date(timeIntervalSince1970: 0)
        let pace5h = UsageEvent(time: at, provider: .claude, kind: .pace, window: "5h", fraction: 0.5, notified: true)
        #expect(focus.outlines(.claude, on: "2026-10-01"))
        #expect(!focus.outlines(.codex, on: "2026-10-01"))
        #expect(!focus.outlines(.claude, on: "2026-10-02"))
        #expect(focus.highlights(pace5h, on: "2026-10-01"))
        #expect(!focus.highlights(pace5h, on: "2026-10-02"))
        var other = pace5h; other.window = "7d"
        #expect(!focus.highlights(other, on: "2026-10-01"))
        other = pace5h; other.provider = .codex
        #expect(!focus.highlights(other, on: "2026-10-01"))

        // A coalesced band link names no provider: the band is highlighted on every card.
        model.show(DashboardRoute(day: "2026-10-01", event: .band80))
        let band = UsageEvent(time: at, provider: .codex, kind: .band80, fraction: 0.8, notified: true)
        #expect(model.focus?.highlights(band, on: "2026-10-01") == true)
        #expect(model.focus?.outlines(.codex, on: "2026-10-01") == false)

        model.show(DashboardRoute())
        #expect(model.focus == nil)
    }


    @Test("split accounts stacks tokens by account, rest unattributed, totals unchanged (V53, V68)")
    func splitTokens() {
        let range = DashboardRange.days7.statsRange(today: Self.today)
        let day = DayFile(date: Self.today, timeZone: "UTC", records: [DayRecord(
            provider: .claude, tokens: 300, accounts: [
                DayAccount(key: "work-demo", label: "work-demo", billingModel: .subscription, tokens: 200),
                DayAccount(key: "default", label: "default", billingModel: .subscription, tokens: 60),
            ], origin: .observed)])
        let split = DashboardOverview(days: [day], range: range, split: true)
        #expect(split.tokensPerDay.map(\.part) == [.account("work-demo"), .account("default"), .unattributed])
        #expect(split.tokensPerDay.map(\.amount) == [200, 60, 40])
        #expect(split.seriesName(.claude, .account("work-demo")) == "\(ProviderID.claude.displayHint) · work-demo")
        let whole = DashboardOverview(days: [day], range: range)
        #expect(whole.tokensPerDay.map(\.amount) == [300])
    }
}

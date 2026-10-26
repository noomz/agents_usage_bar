import Foundation
import Testing
@testable import AgentsUsageBar

/// SPEC V2, V53, V55, V56 — Calendar.
@Suite("DashboardCalendar")
struct DashboardCalendarTests {
    private static let today = "2026-10-25"
    /// 2026-09-16 through today. Claude gaps on 09-22, 09-29, 10-06, 10-13, 10-20.
    private static let days = SyntheticHistory.days(endingAt: today, count: 40)

    private func calendar(
        _ metric: DashboardCalendar.Metric = .spend,
        days: [DayFile] = Self.days,
        today: String = Self.today,
        excluded: Set<ProviderID> = [],
        firstWeekday: Int = 1
    ) -> DashboardCalendar {
        DashboardCalendar(days: days, today: today, metric: metric, excluded: excluded, firstWeekday: firstWeekday)
    }

    private func day(_ key: String, in calendar: DashboardCalendar) -> DashboardCalendar.Day? {
        calendar.months.flatMap(\.days).first { $0.key == key }
    }

    @Test("every retained month, newest first, with Gregorian grid math from day keys (V2, V55)")
    func monthsFromDayKeys() {
        let grid = calendar()
        #expect(grid.months.map(\.key) == ["2026-10", "2026-09"])
        #expect(grid.months.map(\.days.count) == [31, 30])
        #expect(grid.months[0].days.first?.key == "2026-10-01")
        #expect(grid.months[0].days.last?.key == "2026-10-31")
        // 2026-10-01 is a Thursday.
        #expect(grid.months[0].leadingBlanks == 4)
        #expect(calendar(firstWeekday: 2).months[0].leadingBlanks == 3)

        let rollover = calendar(days: SyntheticHistory.days(endingAt: "2028-03-02", count: 70), today: "2028-03-02")
        #expect(rollover.months.map(\.key) == ["2028-03", "2028-02", "2028-01", "2027-12"])
        #expect(rollover.months[1].days.count == 29)
    }

    @Test("days outside retention are inert; today is in progress (V55)")
    func retentionAndToday() throws {
        let grid = calendar()
        let today = try #require(day(Self.today, in: grid))
        #expect(today.isToday && today.retained)
        let future = try #require(day("2026-10-26", in: grid))
        #expect(!future.retained && !future.partial && future.amount == nil)
        let before = try #require(day("2026-09-15", in: grid))
        #expect(!before.retained && !before.partial)
        #expect(calendar().panel(Self.today).isToday)
    }

    @Test("the metric picker colours by metered spend, value, or quota peak, never summed (V26, V55)")
    func metrics() throws {
        // OpenRouter $3.50 is the only spend: Claude is subscription, Codex cannot be split.
        let spend = try #require(day(Self.today, in: calendar(.spend)))
        #expect(spend.amount == Decimal(string: "3.5"))
        #expect(!spend.estimated)
        let value = try #require(day(Self.today, in: calendar(.value)))
        #expect(value.amount == 5)
        #expect(value.estimated)
        let peak = try #require(day(Self.today, in: calendar(.quotaPeak)))
        #expect(peak.peak == 1.0)
        #expect(peak.amount == nil)
    }

    @Test("a gap day or a missing day file gets a dashed border; partial months are incomplete (V56)")
    func partialDays() throws {
        let grid = calendar()
        #expect(try #require(day("2026-10-20", in: grid)).partial)
        #expect(try !#require(day("2026-10-21", in: grid)).partial)
        // Retention starts on 09-16, so September is incomplete; October has Claude gaps.
        #expect(grid.months.map(\.incomplete) == [true, true])

        let missing = Self.days.filter { $0.date != "2026-10-10" }
        #expect(try #require(day("2026-10-10", in: calendar(days: missing))).partial)

        let complete = calendar(days: SyntheticHistory.days(endingAt: "2026-10-05", count: 5), today: "2026-10-05")
        #expect(complete.months.map(\.incomplete) == [false])
    }

    @Test("chips filter the heatmap: amounts, peaks, events, and gaps (V53)")
    func chipsFilterHeatmap() throws {
        let without = calendar(.quotaPeak, excluded: [.claude])
        #expect(try !#require(day("2026-10-20", in: without)).partial)
        let today = try #require(day(Self.today, in: without))
        #expect(!today.hasEvent)
        // Today's Codex record is backfilled, with no quota (V30).
        #expect(today.peak == nil)
        #expect(try #require(day("2026-10-24", in: without)).peak == 0.5)
        #expect(try #require(day(Self.today, in: calendar())).hasEvent)
        #expect(try !#require(day("2026-10-21", in: calendar())).hasEvent)
        #expect(Set(calendar().chipProviders) == [.claude, .codex, .openrouter])
    }

    @Test("local runtimes show presence only and are never drawn as $0 (V56)")
    func localNeverZero() throws {
        let local = Self.days.map { day in
            DayFile(date: day.date, timeZone: day.timeZone, records: day.records.filter { $0.provider == .ollama })
        }
        let grid = calendar(days: local)
        #expect(grid.chipProviders.isEmpty)
        #expect(grid.months.flatMap(\.days).allSatisfy { $0.amount == nil && !$0.partial })
        let card = try #require(grid.panel(Self.today).cards.first)
        #expect(card.provider == .ollama && card.kind == .local && card.record != nil)
        #expect(grid.panel("2026-10-26").cards.isEmpty)
    }

    @Test("the day panel has every provider, gap cards, backfilled records, and events, whatever the chips (V55, V56)")
    func dayPanel() throws {
        let gapDay = calendar(excluded: [.claude]).panel("2026-10-20")
        #expect(Set(gapDay.cards.map(\.provider)) == [.claude, .codex, .openrouter, .ollama])
        #expect(gapDay.cards.first { $0.provider == .claude }?.record == nil)

        let today = calendar().panel(Self.today)
        let codex = try #require(today.cards.first { $0.provider == .codex })
        #expect(codex.record?.origin == .backfilled)
        #expect(codex.kind == .mixed)
        let claude = try #require(today.cards.first { $0.provider == .claude })
        #expect(claude.events.map(\.kind) == [.band80])
        #expect(today.budgetEvents.isEmpty)
    }

    @Test("total-budget events, which have no provider, show apart in the panel")
    func budgetEvents() throws {
        var days = Self.days
        let budget = UsageEvent(time: Date(timeIntervalSince1970: 1_800_000_000), provider: nil, kind: .budgetWarning,
                                fraction: 0.8, notified: true)
        days[days.count - 1].events.append(budget)
        let grid = calendar(days: days, excluded: [.claude])
        #expect(grid.panel(Self.today).budgetEvents == [budget])
        #expect(try #require(day(Self.today, in: grid)).hasEvent)
    }
}

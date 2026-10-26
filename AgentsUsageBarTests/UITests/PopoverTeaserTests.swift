import Foundation
import Testing
@testable import AgentsUsageBar

/// SPEC V20, V59 — the popover's 14-day teaser.
@Suite("PopoverTeaser")
struct PopoverTeaserTests {
    private static let today = "2026-10-25"
    private static let days = SyntheticHistory.days(endingAt: today, count: 30)

    private func only(_ ids: Set<ProviderID>, in days: [DayFile] = Self.days) -> [DayFile] {
        days.map { day in
            var day = day
            day.records = day.records.filter { ids.contains($0.provider) }
            return day
        }
    }

    private func record(_ id: ProviderID, _ key: String, in days: [DayFile]) -> DayRecord? {
        days.first { $0.date == key }?.records.first { $0.provider == id }
    }

    @Test("13 sealed days plus today, marked in progress (V59)")
    func fourteenSlots() throws {
        let teaser = try #require(PopoverTeaser(days: Self.days, today: Self.today))
        #expect(teaser.slots.count == 14)
        #expect(teaser.slots.first?.key == "2026-10-12")
        #expect(teaser.slots.last?.key == Self.today)
        #expect(teaser.slots.map(\.isToday) == Array(repeating: false, count: 13) + [true])
    }

    @Test("a metered account in the 14 days plots daily metered spend (V59, V26)")
    func spend() throws {
        let days = only([.openrouter, .claude])
        let teaser = try #require(PopoverTeaser(days: days, today: Self.today))
        #expect(teaser.metric == .spend)
        #expect(teaser.metric.title == "Spend 14d")
        for slot in teaser.slots {
            let cost = try #require(record(.openrouter, slot.key, in: days)?.costUSD?.amount)
            // Claude is subscription: its value never enters spend.
            #expect(slot.value == NSDecimalNumber(decimal: cost).doubleValue)
        }
    }

    @Test("no metered account plots the daily highest quota peak (V59)")
    func peak() throws {
        let days = only([.claude])
        let teaser = try #require(PopoverTeaser(days: days, today: Self.today))
        #expect(teaser.metric == .peak)
        #expect(teaser.metric.title == "Peak quota 14d")
        for slot in teaser.slots {
            let expected = record(.claude, slot.key, in: days)?.quota.values.map(\.peak).max()
            #expect(slot.value == expected)
        }
        // Every 7th synthetic day has no Claude record: an empty slot, never zero.
        #expect(teaser.slots.contains { $0.value == nil })
    }

    @Test("a day with no file is an empty slot, never zero (V59)")
    func gapIsEmpty() throws {
        let missing: Set = ["2026-10-15", "2026-10-20"]
        let days = Self.days.filter { !missing.contains($0.date) }
        let teaser = try #require(PopoverTeaser(days: days, today: Self.today))
        #expect(teaser.metric == .spend)
        for slot in teaser.slots {
            #expect((slot.value == nil) == missing.contains(slot.key))
        }
    }

    @Test("no history, or local runtimes only, hides the teaser")
    func hidden() {
        #expect(PopoverTeaser(days: [], today: Self.today) == nil)
        #expect(PopoverTeaser(days: only([.ollama]), today: Self.today) == nil)
    }

    @Test("the source reads the 14 day files from history (V20)")
    func source() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PopoverTeaserTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try SyntheticHistory.write(Self.days, to: directory)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let noon = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)))
        let source = PopoverTeaserSource(
            reader: HistoryReader(directory: directory),
            dayKeys: DayKeyOwner(clock: VirtualClock(fixed: noon), timeZone: utc.timeZone))

        let loaded = await source.load()
        #expect(loaded != nil)
        #expect(loaded == PopoverTeaser(days: Self.days, today: Self.today))
    }
}

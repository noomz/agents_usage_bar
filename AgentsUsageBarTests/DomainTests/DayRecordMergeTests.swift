import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("DayRecordMergeTests")
struct DayRecordMergeTests {

    static let t1 = Date(timeIntervalSince1970: 1_792_000_000)
    static let t2 = t1.addingTimeInterval(300)
    static let t3 = t1.addingTimeInterval(600)

    static func sample(
        _ provider: String = "openrouter",
        tokens: Int? = nil,
        cost: Decimal? = nil,
        balance: Decimal? = nil,
        quota: Quota? = nil,
        windows: [QuotaWindow]? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerID: ProviderID(rawValue: provider), asOf: t1, tokensToday: tokens,
            costTodayUSD: cost, balanceUSD: balance, quota: quota, raw: [:], quotaWindows: windows
        )
    }

    private func fold(_ samples: UsageSnapshot...) -> DayRecord {
        var record = DayRecord(provider: samples[0].providerID, origin: .observed)
        for (index, sample) in samples.enumerated() {
            record = record.merging(sample, at: Self.t1.addingTimeInterval(Double(index) * 300))
        }
        return record
    }

    @Test("totals keep the highest value; a degraded poll cannot shrink them (V7)")
    func totalsKeepHighest() {
        let record = fold(
            Self.sample(tokens: 100, cost: Decimal(string: "1.50")),
            Self.sample(tokens: nil, cost: Decimal(string: "0.20")),
            Self.sample(tokens: 80, cost: nil)
        )
        #expect(record.tokens == 100)
        #expect(record.costUSD == Money(Decimal(string: "1.50")!))
    }

    @Test("unknown totals stay nil, never zero (V7)")
    func unknownStaysNil() {
        let record = fold(Self.sample("ollama"), Self.sample("ollama"))
        #expect(record.tokens == nil)
        #expect(record.costUSD == nil)
        #expect(record.quota.isEmpty)
    }

    @Test("balance keeps the last value seen; nil keeps the prior one (V7)")
    func balanceKeepsLast() {
        let record = fold(Self.sample(balance: 10), Self.sample(balance: 7), Self.sample(balance: nil))
        #expect(record.balanceUSD == Money(7))
    }

    @Test("quota keeps peak with its resetsAt, and the last value as end of day (V8)")
    func quotaPeakAndEndOfDay() {
        let resetA = Self.t1.addingTimeInterval(3600)
        let resetB = Self.t1.addingTimeInterval(7200)
        let record = fold(
            Self.sample("claude", windows: [QuotaWindow(name: "5h", utilization: 0.4, resetsAt: resetA)]),
            Self.sample("claude", windows: [QuotaWindow(name: "5h", utilization: 0.9, resetsAt: resetA)]),
            // The window reset mid-day: the day keeps its highest value (V8).
            Self.sample("claude", windows: [QuotaWindow(name: "5h", utilization: 0.1, resetsAt: resetB),
                                            QuotaWindow(name: "7d", utilization: 0.3, resetsAt: nil),
                                            QuotaWindow(name: "7d-opus", utilization: nil, resetsAt: nil)])
        )
        #expect(record.quota["5h"] == QuotaDay(peak: 0.9, peakResetsAt: resetA, endOfDay: 0.1))
        #expect(record.quota["7d"] == QuotaDay(peak: 0.3, endOfDay: 0.3))
        #expect(record.quota["7d-opus"] == nil)
    }

    @Test("a single quota with no windows is filed under `quota` (V8)")
    func providerQuotaWindow() {
        let record = fold(Self.sample(quota: Quota(used: 3, limit: 4, remaining: 1)))
        #expect(record.quota[UsageSnapshot.providerQuotaWindow] == QuotaDay(peak: 0.75, endOfDay: 0.75))
    }

    @Test("firstSeen is the first good sample, lastSeen the latest (V10)")
    func seenTimes() {
        let record = fold(Self.sample(tokens: 1), Self.sample(tokens: 1), Self.sample(tokens: 1))
        #expect(record.firstSeen == Self.t1)
        #expect(record.lastSeen == Self.t3)
        #expect(record.origin == .observed)
    }

    @Test("day merge: one record per provider, last zone, seen times ignored by the change check (V6, V11, V15)")
    func dayMerge() {
        let empty = DayFile(date: "2026-10-22", timeZone: "Asia/Bangkok")
        let first = empty.merging([Self.sample(tokens: 5), Self.sample("ollama")], at: Self.t1, timeZone: "Asia/Bangkok")
        #expect(first.records.map(\.provider.rawValue) == ["ollama", "openrouter"])

        let again = first.merging([Self.sample(tokens: 5)], at: Self.t2, timeZone: "Asia/Bangkok")
        #expect(again.records.count == 2)
        #expect(again != first)
        #expect(again.hasSameContent(as: first))

        let moved = again.merging([Self.sample(tokens: 5)], at: Self.t3, timeZone: "Asia/Tokyo")
        #expect(moved.timeZone == "Asia/Tokyo")
        #expect(!moved.hasSameContent(as: again))

        #expect(first.merging([], at: Self.t3, timeZone: "UTC") == first)
    }
}

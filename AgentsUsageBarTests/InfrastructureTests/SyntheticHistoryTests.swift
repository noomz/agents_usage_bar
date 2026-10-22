import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("SyntheticHistoryTests")
struct SyntheticHistoryTests {

    @Test("generated days read back through HistoryReader, oldest first, across a month end (C3)")
    func readsBack() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let days = SyntheticHistory.days(endingAt: "2026-11-02", count: 90)
        try SyntheticHistory.write(days, to: dir)

        let keys = try await HistoryReader(directory: dir).dayKeys()
        #expect(keys.count == 90)
        #expect(keys.first == "2026-08-05")
        #expect(keys.last == "2026-11-02")
        #expect(try await HistoryReader(directory: dir).days() == days)
    }

    @Test("the same arguments give the same bytes, so goldens are stable (C3)")
    func deterministic() throws {
        let a = try SyntheticHistory.days(endingAt: "2026-10-22", count: 14).map { try $0.encoded() }
        let b = try SyntheticHistory.days(endingAt: "2026-10-22", count: 14).map { try $0.encoded() }
        #expect(a == b)
    }

    @Test("no email and only round money in the bytes (C3, V22)")
    func syntheticOnly() throws {
        for day in SyntheticHistory.days(endingAt: "2026-10-22", count: 90) {
            #expect(!String(decoding: try day.encoded(), as: UTF8.self).contains("@"))
            let amounts = day.records.flatMap { record in
                [record.costUSD, record.balanceUSD] + record.accounts.map(\.costUSD)
            }.compactMap { $0?.amount }
            for amount in amounts {
                #expect((amount * 4).isWholeNumber, "\(day.date) has \(amount)")
            }
        }
    }

    @Test("covers every billing model, gaps, backfilled days, and events (V11, V25, V30)")
    func coverage() {
        let days = SyntheticHistory.days(endingAt: "2026-10-22", count: 14)
        let records = days.flatMap(\.records)
        let models = Set(records.flatMap(\.accounts).map(\.billingModel))
        #expect(models == [.metered, .subscription, .local])
        #expect(days.contains { day in !day.records.contains { $0.provider.rawValue == "claude" } })
        let backfilled = records.filter { $0.origin == .backfilled }
        #expect(!backfilled.isEmpty)
        #expect(backfilled.allSatisfy { $0.quota.isEmpty && $0.firstSeen == nil && $0.lastSeen == nil })
        #expect(records.contains { $0.provider.rawValue == "ollama" && $0.tokens == nil && $0.costUSD == nil })
        #expect(days.contains { !$0.events.isEmpty })
    }
}

private extension Decimal {
    var isWholeNumber: Bool {
        var value = self
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return rounded == self
    }
}

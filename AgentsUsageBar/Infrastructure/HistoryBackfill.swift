import Foundation
import os.log

/// A provider's past days rebuilt from data it still keeps (SPEC V28, I10).
public protocol BackfillSource: Sendable {
    var provider: ProviderID { get }
    /// How many days before today the source still holds, or nil when it cannot run now
    /// (for example, no management key). Days it cannot run for stay unchecked (V29).
    func reachDays() async -> Int?
    /// Backfilled records for the days in `keys` that had usage. A day left out had none.
    func records(for keys: [String]) async throws -> [String: DayRecord]
    /// Every account known now, with its billing model and plan from I6. A new backfilled
    /// record lists them all, since the source data names no account (V25, V62).
    func accounts() async -> [UsageSnapshot.AccountUsage]
}

/// One gap-fill pass (V27): each source in turn, one at a time, over the sealed days in its
/// reach that it has not checked yet (V29). A day in reach with no usage gets a zero record
/// (V30). Writes go through `HistoryStore.backfill(_:on:)` (V32).
struct HistoryBackfill: Sendable {
    let sources: [any BackfillSource]
    let reader: HistoryReader
    let dayKeys: DayKeyOwner
    private let logger = AppLogger.logger(category: "history")

    init(sources: [any BackfillSource], reader: HistoryReader, dayKeys: DayKeyOwner) {
        self.sources = sources
        self.reader = reader
        self.dayKeys = dayKeys
    }

    func run(into store: HistoryStore) async {
        for source in sources {
            await fill(source, into: store)
        }
    }

    private func fill(_ source: any BackfillSource, into store: HistoryStore) async {
        guard let today = await store.openDayKey, let reach = await source.reachDays(), reach > 0 else { return }
        let depth = min(reach, HistoryStore.retainedDays)
        var keys: [String] = []
        for back in (1...depth).reversed() {
            guard let key = dayKeys.key(today, addingDays: -back) else { continue }
            if await reader.day(key)?.backfillChecked.contains(source.provider) != true {
                keys.append(key)
            }
        }
        guard !keys.isEmpty else { return }
        let records: [String: DayRecord]
        do {
            records = try await source.records(for: keys)
        } catch {
            // The days stay unchecked, so the next pass tries them again.
            logger.error("history backfill \(source.provider.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let accounts = await store.backfillAccounts(await source.accounts(), of: source.provider)
        for key in keys {
            var record = records[key] ?? DayRecord(
                provider: source.provider, tokens: 0, costUSD: Money(0), origin: .backfilled)
            record.accounts = accounts
            await store.backfill(record, on: key)
        }
    }
}

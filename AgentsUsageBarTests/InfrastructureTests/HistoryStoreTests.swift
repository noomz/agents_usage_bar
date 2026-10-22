import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("HistoryStoreTests")
struct HistoryStoreTests {

    private static let utc = TimeZone(identifier: "UTC")!

    private static func pid(_ raw: String) -> ProviderID {
        ProviderID(rawValue: raw)
    }

    private static func at(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private static func dayKeys() -> DayKeyOwner {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = utc
        return DayKeyOwner(clock: VirtualClock(fixed: at("2026-10-22T12:00:00Z")), timeZone: utc, legacyCalendar: gregorian)
    }

    private func makeDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func makeStore(_ dir: URL) -> HistoryStore {
        HistoryStore(directory: dir, dayKeys: Self.dayKeys())
    }

    private func read(_ key: String, in dir: URL) async -> DayFile? {
        await HistoryReader(directory: dir).day(key)
    }

    /// The file's inode: an atomic write renames a new file into place, so it changes.
    private func inode(_ key: String, in dir: URL) throws -> Int? {
        let path = dir.appending(path: "\(key).json").path(percentEncoded: false)
        return try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
    }

    private func sample(_ provider: String = "openrouter", tokens: Int? = nil, cost: Decimal? = nil) -> UsageSnapshot {
        DayRecordMergeTests.sample(provider, tokens: tokens, cost: cost)
    }

    private func writeRaw(_ day: DayFile, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try day.encoded().write(to: dir.appending(path: "\(day.date).json"))
    }

    @Test("records every provider .ok that poll, including local nil totals (V11)")
    func recordsPresence() async throws {
        let dir = makeDirectory()
        let store = makeStore(dir)
        await store.record([sample(tokens: 10, cost: 1), sample("ollama")], at: Self.at("2026-10-22T09:00:00Z"))

        let day = try #require(await read("2026-10-22", in: dir))
        #expect(day.timeZone == Self.utc.identifier)
        #expect(day.records.map(\.provider.rawValue) == ["ollama", "openrouter"])
        let local = try #require(day.records.first)
        #expect(local.tokens == nil && local.costUSD == nil)
        #expect(local.origin == .observed)
    }

    @Test("a poll with no good samples creates nothing (V11, C4)")
    func noSamplesNoFile() async {
        let dir = makeDirectory()
        await makeStore(dir).record([], at: Self.at("2026-10-22T09:00:00Z"))
        #expect(!FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
    }

    @Test("no change means no write; seen times ride the next changed write (V15)")
    func writesOnlyOnChange() async throws {
        let dir = makeDirectory()
        let store = makeStore(dir)
        let t1 = Self.at("2026-10-22T09:00:00Z")
        let t2 = Self.at("2026-10-22T09:05:00Z")
        let t3 = Self.at("2026-10-22T09:10:00Z")

        await store.record([sample(tokens: 10)], at: t1)
        let first = try inode("2026-10-22", in: dir)
        await store.record([sample(tokens: 10)], at: t2)
        #expect(try inode("2026-10-22", in: dir) == first)
        #expect(await read("2026-10-22", in: dir)?.records.first?.lastSeen == t1)

        await store.record([sample(tokens: 12)], at: t3)
        #expect(try inode("2026-10-22", in: dir) != first)
        let record = try #require(await read("2026-10-22", in: dir)?.records.first)
        #expect(record.tokens == 12)
        #expect(record.firstSeen == t1)
        #expect(record.lastSeen == t3)
    }

    @Test("launch seeds the open day from disk, keeping events and higher totals (V7, V15)")
    func seedsFromDisk() async throws {
        let dir = makeDirectory()
        let event = UsageEvent(time: Self.at("2026-10-22T08:00:00Z"), provider: Self.pid("openrouter"), kind: .band80,
                               fraction: 0.8, notified: true)
        try writeRaw(DayFile(
            date: "2026-10-22", timeZone: Self.utc.identifier,
            records: [DayRecord(provider: Self.pid("openrouter"), tokens: 500, origin: .observed,
                                firstSeen: Self.at("2026-10-22T01:00:00Z"), lastSeen: Self.at("2026-10-22T08:00:00Z"))],
            events: [event], backfillChecked: [Self.pid("claude")]
        ), in: dir)
        let before = try inode("2026-10-22", in: dir)

        let store = makeStore(dir)
        await store.record([sample(tokens: 300)], at: Self.at("2026-10-22T09:00:00Z"))
        #expect(try inode("2026-10-22", in: dir) == before)

        await store.record([sample(tokens: 300), sample("ollama")], at: Self.at("2026-10-22T09:05:00Z"))
        let day = try #require(await read("2026-10-22", in: dir))
        #expect(day.events == [event])
        #expect(day.backfillChecked == [Self.pid("claude")])
        #expect(day.records.first { $0.provider == Self.pid("openrouter") }?.tokens == 500)
        #expect(day.records.first { $0.provider == Self.pid("openrouter") }?.firstSeen == Self.at("2026-10-22T01:00:00Z"))
    }

    @Test("the first poll on a later key seals the previous day, which polling never writes again (V12, V16)")
    func sealsPreviousDay() async throws {
        let dir = makeDirectory()
        let store = makeStore(dir)
        let lateMonday = Self.at("2026-10-19T23:55:00Z")
        await store.record([sample(tokens: 40)], at: Self.at("2026-10-19T23:50:00Z"))
        await store.record([sample(tokens: 40)], at: lateMonday)

        // Wakes Thursday: provider totals are Thursday's own; nothing is split back (V12).
        await store.record([sample(tokens: 3)], at: Self.at("2026-10-22T08:00:00Z"))
        let monday = try #require(await read("2026-10-19", in: dir))
        #expect(monday.records.first?.tokens == 40)
        #expect(monday.records.first?.lastSeen == lateMonday)
        #expect(await read("2026-10-20", in: dir) == nil)
        #expect(await read("2026-10-22", in: dir)?.records.first?.tokens == 3)

        let sealed = try inode("2026-10-19", in: dir)
        await store.record([sample(tokens: 9)], at: Self.at("2026-10-22T09:00:00Z"))
        // A wall clock that goes back still writes the open key (V16).
        await store.record([sample(tokens: 11)], at: Self.at("2026-10-19T10:00:00Z"))
        #expect(try inode("2026-10-19", in: dir) == sealed)
        #expect(await read("2026-10-22", in: dir)?.records.first?.tokens == 11)
    }

    @Test("prune deletes keys more than 90 days back and leaves files it cannot read (V17, V18)")
    func prunesPast90Days() async throws {
        let dir = makeDirectory()
        for key in ["2026-07-23", "2026-07-24", "2026-10-21"] {
            try writeRaw(DayFile(date: key, timeZone: Self.utc.identifier), in: dir)
        }
        let future = Data(#"{"schemaVersion": 99, "date": "2026-07-01"}"#.utf8)
        try future.write(to: dir.appending(path: "2026-07-01.json"))

        await makeStore(dir).record([], at: Self.at("2026-10-22T09:00:00Z"))
        let keys = try await HistoryReader(directory: dir).dayKeys()
        #expect(keys == ["2026-07-01", "2026-07-24", "2026-10-21"])
        #expect(try Data(contentsOf: dir.appending(path: "2026-07-01.json")) == future)
    }

    @Test("an open day file this build cannot read is never overwritten (V18)")
    func skippedOpenDayIsKept() async throws {
        let dir = makeDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let future = Data(#"{"schemaVersion": 99, "date": "2026-10-22"}"#.utf8)
        try future.write(to: dir.appending(path: "2026-10-22.json"))

        let store = makeStore(dir)
        await store.record([sample(tokens: 10)], at: Self.at("2026-10-22T09:00:00Z"))
        await store.record([sample(tokens: 20)], at: Self.at("2026-10-22T09:05:00Z"))
        #expect(try Data(contentsOf: dir.appending(path: "2026-10-22.json")) == future)
    }

    @Test("a poll writes .ok providers only; a stale snapshot is not a sample (I4, V11)")
    @MainActor
    func aggregateStoreRecordsAfterPoll() async throws {
        let dir = makeDirectory()
        let ok = FakeProvider(id: Self.pid("openrouter"), displayName: "OpenRouter",
                              result: .success(sample(tokens: 7, cost: 2)))
        let failing = FakeProvider(id: Self.pid("claude"), displayName: "Claude",
                                   result: .failure(ProviderError(kind: .network, message: "offline")))
        let store = AggregateStore(
            registry: [ok, failing],
            clock: VirtualClock(fixed: Self.at("2026-10-22T09:00:00Z")),
            cache: AggFakeCacheStore(providers: [
                Self.pid("claude"): ProviderState(id: Self.pid("claude"), displayName: "Claude",
                                        snapshot: sample("claude", tokens: 99),
                                        status: .ok(lastSuccess: Self.at("2026-10-21T09:00:00Z")),
                                        lastSuccess: Self.at("2026-10-21T09:00:00Z")),
            ]),
            thresholds: ThresholdEngine(warningFraction: 0.8, dayKeys: Self.dayKeys()),
            notifications: SpyNotificationManager(),
            dayKeys: Self.dayKeys(),
            history: makeStore(dir)
        )
        await store.refresh(now: Self.at("2026-10-22T09:00:00Z"))

        let day = try #require(await read("2026-10-22", in: dir))
        #expect(day.records.map(\.provider.rawValue) == ["openrouter"])
        #expect(day.records.first?.costUSD == Money(2))
    }
}

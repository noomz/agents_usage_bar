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

    private static func dayKeys(_ zone: TimeZone = utc) -> DayKeyOwner {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = zone
        return DayKeyOwner(clock: VirtualClock(fixed: at("2026-10-22T12:00:00Z")), timeZone: zone, legacyCalendar: gregorian)
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
            records: [DayRecord(provider: Self.pid("openrouter"), tokens: 500,
                                accounts: [DayAccount(key: "default", label: "default", billingModel: .metered)],
                                origin: .observed, firstSeen: Self.at("2026-10-22T01:00:00Z"), lastSeen: Self.at("2026-10-22T08:00:00Z"))],
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
        // A wall clock that goes back 1 day still writes the open key (V4, V16).
        await store.record([sample(tokens: 11)], at: Self.at("2026-10-21T10:00:00Z"))
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

    // MARK: V4, V5, V6, V12 — monotonic day key (T6, ADR 0002)

    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private static let honolulu = TimeZone(identifier: "Pacific/Honolulu")!
    private static let newYork = TimeZone(identifier: "America/New_York")!

    private func dayKeys(in dir: URL) async throws -> [String] {
        try await HistoryReader(directory: dir).dayKeys()
    }

    @Test("sleep Mon to Thu: Mon keeps its usage, Tue and Wed are gaps (V12)")
    func sleepThroughDays() async throws {
        let dir = makeDirectory()
        let store = makeStore(dir)
        await store.record([sample(tokens: 10)], at: Self.at("2026-10-19T09:00:00Z"))
        await store.record([sample(tokens: 5)], at: Self.at("2026-10-22T09:00:00Z"))

        #expect(try await dayKeys(in: dir) == ["2026-10-19", "2026-10-22"])
        #expect(await read("2026-10-19", in: dir)?.records.first?.tokens == 10)
        #expect(await read("2026-10-22", in: dir)?.records.first?.tokens == 5)
    }

    @Test("Tokyo to Honolulu: the earlier wall date keeps writing the newest key (V4, V6)")
    func tokyoToHonolulu() async throws {
        let dir = makeDirectory()
        // 2026-10-22 09:00 JST
        await HistoryStore(directory: dir, dayKeys: Self.dayKeys(Self.tokyo))
            .record([sample(tokens: 10)], at: Self.at("2026-10-22T00:00:00Z"))

        // Landed: 2026-10-21 19:00 HST.
        let owner = Self.dayKeys(Self.honolulu)
        let store = HistoryStore(directory: dir, dayKeys: owner)
        let landed = Self.at("2026-10-22T05:00:00Z")
        await store.record([sample(tokens: 20)], at: landed)

        #expect(owner.wallKey(for: landed) == "2026-10-21")
        #expect(owner.key(for: landed) == "2026-10-22")
        #expect(try await dayKeys(in: dir) == ["2026-10-22"])
        let day = try #require(await read("2026-10-22", in: dir))
        #expect(day.timeZone == Self.honolulu.identifier)
        #expect(day.records.first?.tokens == 20)

        // The wall date catches up (02:00 HST Oct 22), then passes it (02:00 HST Oct 23).
        await store.record([sample(tokens: 30)], at: Self.at("2026-10-22T12:00:00Z"))
        await store.record([sample(tokens: 1)], at: Self.at("2026-10-23T12:00:00Z"))
        #expect(try await dayKeys(in: dir) == ["2026-10-22", "2026-10-23"])
        #expect(await read("2026-10-22", in: dir)?.records.first?.tokens == 30)
    }

    @Test("Honolulu to Tokyo: the date skips forward and the earlier day is sealed (V4, V16)")
    func honoluluToTokyo() async throws {
        let dir = makeDirectory()
        // 2026-10-21 10:00 HST
        await HistoryStore(directory: dir, dayKeys: Self.dayKeys(Self.honolulu))
            .record([sample(tokens: 10)], at: Self.at("2026-10-21T20:00:00Z"))

        // Landed: 2026-10-22 07:00 JST.
        let store = HistoryStore(directory: dir, dayKeys: Self.dayKeys(Self.tokyo))
        await store.record([sample(tokens: 3)], at: Self.at("2026-10-21T22:00:00Z"))

        #expect(try await dayKeys(in: dir) == ["2026-10-21", "2026-10-22"])
        let earlier = try #require(await read("2026-10-21", in: dir))
        #expect(earlier.timeZone == Self.honolulu.identifier)
        #expect(earlier.records.first?.tokens == 10)
        let later = try #require(await read("2026-10-22", in: dir))
        #expect(later.timeZone == Self.tokyo.identifier)
        #expect(later.records.first?.tokens == 3)
    }

    @Test("New York DST spring forward: the 23-hour day is one day file (V6)")
    func dstSpringForward() async throws {
        let dir = makeDirectory()
        let store = HistoryStore(directory: dir, dayKeys: Self.dayKeys(Self.newYork))
        await store.record([sample(tokens: 1)], at: Self.at("2026-03-08T04:30:00Z"))  // Mar 7 23:30 EST
        await store.record([sample(tokens: 2)], at: Self.at("2026-03-08T06:30:00Z"))  // Mar 8 01:30 EST
        await store.record([sample(tokens: 3)], at: Self.at("2026-03-08T07:30:00Z"))  // Mar 8 03:30 EDT
        await store.record([sample(tokens: 4)], at: Self.at("2026-03-09T03:59:00Z"))  // Mar 8 23:59 EDT
        await store.record([sample(tokens: 5)], at: Self.at("2026-03-09T04:01:00Z"))  // Mar 9 00:01 EDT

        #expect(try await dayKeys(in: dir) == ["2026-03-07", "2026-03-08", "2026-03-09"])
        let day = try #require(await read("2026-03-08", in: dir)?.records.first)
        #expect(day.tokens == 4)
        #expect(day.firstSeen == Self.at("2026-03-08T06:30:00Z"))
        #expect(day.lastSeen == Self.at("2026-03-09T03:59:00Z"))
    }

    @Test("New York DST fall back: the 25-hour day is one day file (V6)")
    func dstFallBack() async throws {
        let dir = makeDirectory()
        let store = HistoryStore(directory: dir, dayKeys: Self.dayKeys(Self.newYork))
        await store.record([sample(tokens: 1)], at: Self.at("2026-11-01T03:59:00Z"))  // Oct 31 23:59 EDT
        await store.record([sample(tokens: 2)], at: Self.at("2026-11-01T04:01:00Z"))  // Nov 1 00:01 EDT
        await store.record([sample(tokens: 3)], at: Self.at("2026-11-01T05:30:00Z"))  // Nov 1 01:30 EDT
        await store.record([sample(tokens: 4)], at: Self.at("2026-11-01T06:30:00Z"))  // Nov 1 01:30 EST
        await store.record([sample(tokens: 5)], at: Self.at("2026-11-02T04:59:00Z"))  // Nov 1 23:59 EST
        await store.record([sample(tokens: 6)], at: Self.at("2026-11-02T05:01:00Z"))  // Nov 2 00:01 EST

        #expect(try await dayKeys(in: dir) == ["2026-10-31", "2026-11-01", "2026-11-02"])
        let day = try #require(await read("2026-11-01", in: dir)?.records.first)
        #expect(day.tokens == 5)
        let first = try #require(day.firstSeen)
        let last = try #require(day.lastSeen)
        #expect(last.timeIntervalSince(first) == 25 * 3600 - 2 * 60)
    }

    @Test("clock set back 1 day keeps writing the newest key (V4)")
    func clockBackOneDay() async throws {
        let dir = makeDirectory()
        let store = makeStore(dir)
        await store.record([sample(tokens: 10)], at: Self.at("2026-10-22T09:00:00Z"))
        await store.record([sample(tokens: 20)], at: Self.at("2026-10-21T09:00:00Z"))

        #expect(try await dayKeys(in: dir) == ["2026-10-22"])
        #expect(await read("2026-10-22", in: dir)?.records.first?.tokens == 20)
    }

    @Test("clock set back 10 days pauses writes and holds the key (V4, V5)")
    func clockBackTenDays() async throws {
        let dir = makeDirectory()
        let owner = Self.dayKeys()
        let store = HistoryStore(directory: dir, dayKeys: owner)
        await store.record([sample(tokens: 10)], at: Self.at("2026-10-22T09:00:00Z"))

        let wrong = Self.at("2026-10-12T09:00:00Z")
        await store.record([sample(tokens: 50)], at: wrong)
        #expect(owner.key(for: wrong) == "2026-10-22")
        #expect(try await dayKeys(in: dir) == ["2026-10-22"])
        #expect(await read("2026-10-22", in: dir)?.records.first?.tokens == 10)

        // Clock fixed: writes resume on the newest key.
        await store.record([sample(tokens: 60)], at: Self.at("2026-10-22T10:00:00Z"))
        #expect(await read("2026-10-22", in: dir)?.records.first?.tokens == 60)
    }

    @Test("after a relaunch the newest day file sets the key; a clock set back writes nothing older (V4, V5)")
    func relaunchSeedsFromNewestFile() async throws {
        let dir = makeDirectory()
        try writeRaw(DayFile(date: "2026-10-20", timeZone: "UTC"), in: dir)
        try writeRaw(DayFile(date: "2026-10-22", timeZone: "UTC"), in: dir)

        let owner = Self.dayKeys()
        let store = HistoryStore(directory: dir, dayKeys: owner)
        await store.seedNewestKey()
        #expect(owner.key(for: Self.at("2026-10-21T09:00:00Z")) == "2026-10-22")

        await store.record([sample(tokens: 7)], at: Self.at("2026-10-12T09:00:00Z"))
        await store.record([sample(tokens: 8)], at: Self.at("2026-10-21T09:00:00Z"))
        #expect(try await dayKeys(in: dir) == ["2026-10-20", "2026-10-22"])
        #expect(await read("2026-10-22", in: dir)?.records.first?.tokens == 8)
    }

    // MARK: - Account salt (V21, ADR 0003)

    private func codexSample(accountID: String) -> UsageSnapshot {
        var codex = sample("codex", tokens: 1)
        codex.accountInfo = AccountInfo(billingModel: .subscription, plan: "plus", accountID: accountID)
        return codex
    }

    @Test("a Codex account id is stored only as its salted key; the salt is made once, 0600 (V21)")
    func saltedCodexKey() async throws {
        let dir = makeDirectory()
        let rawID = "synthetic-account-0001"
        await makeStore(dir).record([codexSample(accountID: rawID)], at: Self.at("2026-10-22T09:00:00Z"))

        let saltURL = dir.appending(path: HistoryStore.saltFileName)
        let salt = try Data(contentsOf: saltURL)
        let mode = try FileManager.default.attributesOfItem(atPath: saltURL.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let bytes = try Data(contentsOf: dir.appending(path: "2026-10-22.json"))
        #expect(String(decoding: bytes, as: UTF8.self).contains(rawID) == false)
        let account = try #require(await read("2026-10-22", in: dir)?.records.first?.accounts.first)
        #expect(account.key == DayAccount.key(forAccountID: rawID, salt: salt))
        #expect(account.label == "plus")

        // A relaunch reuses the salt, so the same login keeps its key.
        await makeStore(dir).record([codexSample(accountID: rawID)], at: Self.at("2026-10-22T10:00:00Z"))
        #expect(try Data(contentsOf: saltURL) == salt)
        #expect(await read("2026-10-22", in: dir)?.records.first?.accounts.map(\.key) == [account.key])
    }

    @Test("no account id needs no salt, so none is made (V21, C4)")
    func noSaltWithoutAccountID() async {
        let dir = makeDirectory()
        await makeStore(dir).record([sample(tokens: 1)], at: Self.at("2026-10-22T09:00:00Z"))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: HistoryStore.saltFileName).path(percentEncoded: false)))
    }
}

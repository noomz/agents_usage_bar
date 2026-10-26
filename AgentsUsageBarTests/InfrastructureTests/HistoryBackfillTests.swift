import Testing
import Foundation
import os
@testable import AgentsUsageBar

/// A backfill source with fixed usage that logs what each pass asked it for.
private actor FakeSource: BackfillSource {
    nonisolated let provider: ProviderID
    private var reach: Int?
    private let usage: [String: DayRecord]
    private let known: [UsageSnapshot.AccountUsage]
    private let fails: Bool
    private let tracker: OverlapTracker?
    private(set) var requested: [[String]] = []
    nonisolated let unheld = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    init(
        _ provider: String, reach: Int?, usage: [String: DayRecord] = [:],
        accounts: [UsageSnapshot.AccountUsage] = [], fails: Bool = false, tracker: OverlapTracker? = nil
    ) {
        self.provider = ProviderID(rawValue: provider)
        self.reach = reach
        self.usage = usage
        self.known = accounts
        self.fails = fails
        self.tracker = tracker
    }

    func setReach(_ days: Int?) {
        reach = days
    }

    func reachDays() -> Int? {
        reach
    }

    func records(for keys: [String]) async throws -> [String: DayRecord] {
        requested.append(keys)
        await tracker?.enter()
        try await Task.sleep(for: .milliseconds(20))
        await tracker?.leave()
        if fails { throw URLError(.cannotConnectToHost) }
        return usage.filter { keys.contains($0.key) }
    }

    func accounts() -> [UsageSnapshot.AccountUsage] {
        known
    }

    nonisolated func holds(_ key: String) -> Bool {
        !unheld.withLock { $0.contains(key) }
    }
}

private actor OverlapTracker {
    private var active = 0
    private(set) var maxActive = 0

    func enter() {
        active += 1
        maxActive = max(maxActive, active)
    }

    func leave() {
        active -= 1
    }
}

@Suite("HistoryBackfillTests")
struct HistoryBackfillTests {

    private static let utc = TimeZone(identifier: "UTC")!

    private static func at(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private static func pid(_ raw: String) -> ProviderID {
        ProviderID(rawValue: raw)
    }

    private func makeDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func makeStore(_ dir: URL, _ sources: [any BackfillSource]) -> HistoryStore {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = Self.utc
        let dayKeys = DayKeyOwner(clock: VirtualClock(fixed: Self.at("2026-10-22T12:00:00Z")), timeZone: Self.utc, legacyCalendar: gregorian)
        return HistoryStore(directory: dir, dayKeys: dayKeys, backfillSources: sources)
    }

    /// The first poll on 2026-10-22 seals and starts gap-fill; waits for the pass.
    private func firstPoll(_ store: HistoryStore, _ samples: [UsageSnapshot] = []) async {
        await store.record(samples, at: Self.at("2026-10-22T09:00:00Z"))
        await store.gapFillFinished()
    }

    private func read(_ key: String, in dir: URL) async -> DayFile? {
        await HistoryReader(directory: dir).day(key)
    }

    private func writeRaw(_ day: DayFile, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try day.encoded().write(to: dir.appending(path: "\(day.date).json"))
    }

    private func used(_ provider: String, tokens: Int, cost: Decimal) -> DayRecord {
        DayRecord(provider: Self.pid(provider), tokens: tokens, costUSD: Money(cost), costEstimated: true, origin: .backfilled)
    }

    @Test("the first poll fills sealed days in reach: usage, zero where none, nothing past reach (V27, V30)")
    func fillsReach() async throws {
        let dir = makeDirectory()
        let source = FakeSource("claude", reach: 3, usage: ["2026-10-20": used("claude", tokens: 500, cost: 2)])
        await firstPoll(makeStore(dir, [source]))

        #expect(await source.requested == [["2026-10-19", "2026-10-20", "2026-10-21"]])
        let usedDay = try #require(await read("2026-10-20", in: dir))
        #expect(usedDay.records == [used("claude", tokens: 500, cost: 2)])
        #expect(usedDay.backfillChecked == [Self.pid("claude")])
        #expect(usedDay.events.isEmpty)
        for key in ["2026-10-19", "2026-10-21"] {
            let zero = try #require(await read(key, in: dir))
            #expect(zero.records == [DayRecord(provider: Self.pid("claude"), tokens: 0, costUSD: Money(0), origin: .backfilled)])
            #expect(zero.backfillChecked == [Self.pid("claude")])
        }
        #expect(await read("2026-10-18", in: dir) == nil)
        #expect(await read("2026-10-22", in: dir) == nil)
        let mode = try FileManager.default.attributesOfItem(
            atPath: dir.appending(path: "2026-10-20.json").path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("a backfilled record never carries quota or seen times (V30)")
    func stripsQuotaAndSeen() async throws {
        let dir = makeDirectory()
        var record = used("codex", tokens: 10, cost: 1)
        record.quota = ["5h": QuotaDay(peak: 0.9, endOfDay: 0.5)]
        record.firstSeen = Self.at("2026-10-21T01:00:00Z")
        record.lastSeen = Self.at("2026-10-21T02:00:00Z")
        record.origin = .observed
        let account = UsageSnapshot.AccountUsage(
            name: "default", costTodayUSD: 7, quota: nil,
            quotaWindows: [QuotaWindow(name: "5h", utilization: 0.9, resetsAt: nil)],
            accountInfo: AccountInfo(billingModel: .subscription, plan: "plus"))
        await firstPoll(makeStore(dir, [FakeSource("codex", reach: 1, usage: ["2026-10-21": record], accounts: [account])]))

        let stored = try #require(await read("2026-10-21", in: dir)?.records.first)
        #expect(stored.origin == .backfilled)
        #expect(stored.quota.isEmpty)
        #expect(stored.accounts.map(\.quota) == [[:]])
        #expect(stored.firstSeen == nil)
        #expect(stored.lastSeen == nil)
    }

    @Test("every day a source fills, zero days too, lists all its accounts as assumed with no per-account cost (V25, V62)")
    func listsAssumedAccounts() async throws {
        let dir = makeDirectory()
        let accounts = [
            UsageSnapshot.AccountUsage(
                name: "default", costTodayUSD: 3, quota: nil, quotaWindows: nil,
                accountInfo: AccountInfo(billingModel: .subscription, plan: "max")),
            UsageSnapshot.AccountUsage(
                name: "work", costTodayUSD: nil, quota: nil, quotaWindows: nil,
                accountInfo: AccountInfo(billingModel: .metered)),
        ]
        let source = FakeSource("claude", reach: 2, usage: ["2026-10-21": used("claude", tokens: 5, cost: 1)], accounts: accounts)
        await firstPoll(makeStore(dir, [source]))

        let expected = [
            DayAccount(key: "default", label: "default", billingModel: .subscription, plan: "max", billingModelAssumed: true),
            DayAccount(key: "work", label: "work", billingModel: .metered, billingModelAssumed: true),
        ]
        for key in ["2026-10-20", "2026-10-21"] {
            #expect(try #require(await read(key, in: dir)?.records.first).accounts == expected)
        }
    }

    @Test("an account id is stored only as its salted key (V21, V62)")
    func hashesAccountIDs() async throws {
        let dir = makeDirectory()
        let login = UsageSnapshot.AccountUsage(
            name: "someone@example.com", costTodayUSD: nil, quota: nil, quotaWindows: nil,
            accountInfo: AccountInfo(billingModel: .subscription, plan: "plus", accountID: "acct-raw-id"))
        await firstPoll(makeStore(dir, [FakeSource("codex", reach: 1, accounts: [login])]))

        let account = try #require(await read("2026-10-21", in: dir)?.records.first?.accounts.first)
        let salt = try Data(contentsOf: dir.appending(path: HistoryStore.saltFileName))
        #expect(account.key == DayAccount.key(forAccountID: "acct-raw-id", salt: salt))
        #expect(account.label == "plus")
        let raw = try String(contentsOf: dir.appending(path: "2026-10-21.json"), encoding: .utf8)
        #expect(!raw.contains("acct-raw-id"))
        #expect(!raw.contains("@"))
    }

    @Test("an observed day is only topped up: totals rise, nothing else moves, events stay (V31, V32)")
    func topsUpObserved() async throws {
        let dir = makeDirectory()
        let event = UsageEvent(time: Self.at("2026-10-21T10:00:00Z"), provider: Self.pid("claude"), kind: .band80, fraction: 0.8, notified: true)
        let observed = DayRecord(
            provider: Self.pid("claude"), tokens: 400, costUSD: Money(3), costEstimated: false,
            quota: ["5h": QuotaDay(peak: 0.8, endOfDay: 0.4)],
            accounts: [DayAccount(key: "default", label: "default", billingModel: .metered)],
            origin: .observed, firstSeen: Self.at("2026-10-21T08:00:00Z"), lastSeen: Self.at("2026-10-21T22:00:00Z"))
        let lowCost = DayRecord(provider: Self.pid("codex"), tokens: 100, costUSD: Money(5), origin: .observed)
        try writeRaw(DayFile(date: "2026-10-21", timeZone: "UTC", records: [observed, lowCost], events: [event]), in: dir)
        let claude = FakeSource(
            "claude", reach: 1, usage: ["2026-10-21": used("claude", tokens: 600, cost: 4)],
            accounts: [UsageSnapshot.AccountUsage(name: "work", costTodayUSD: nil, quota: nil, quotaWindows: nil)])
        let codex = FakeSource("codex", reach: 1, usage: ["2026-10-21": used("codex", tokens: 50, cost: 1)])
        await firstPoll(makeStore(dir, [claude, codex]))

        let day = try #require(await read("2026-10-21", in: dir))
        var expected = observed
        expected.tokens = 600
        expected.costUSD = Money(4)
        expected.costEstimated = true
        #expect(day.records == [expected, lowCost])
        #expect(day.events == [event])
        #expect(day.backfillChecked == [Self.pid("claude"), Self.pid("codex")])
    }

    @Test("checked days are not asked for again (V29)")
    func checkedOnce() async throws {
        let dir = makeDirectory()
        let source = FakeSource("claude", reach: 2)
        await firstPoll(makeStore(dir, [source]))
        // A relaunch: a fresh store over the same directory.
        await firstPoll(makeStore(dir, [source]))

        #expect(await source.requested == [["2026-10-20", "2026-10-21"]])
    }

    @Test("a source that cannot run leaves gaps unchecked and fills them once it can (V28, V29)")
    func laterCapable() async throws {
        let dir = makeDirectory()
        let source = FakeSource("openrouter", reach: nil)
        await firstPoll(makeStore(dir, [source]))
        #expect(await source.requested.isEmpty)
        #expect(try await HistoryReader(directory: dir).dayKeys().isEmpty)

        await source.setReach(2)
        await firstPoll(makeStore(dir, [source]))
        #expect(await source.requested == [["2026-10-20", "2026-10-21"]])
        #expect(await read("2026-10-20", in: dir)?.backfillChecked == [Self.pid("openrouter")])
    }

    @Test("an unheld key is not asked for, written, or checked, and fills once held (V63)")
    func unheldKeyWaits() async throws {
        let dir = makeDirectory()
        let source = FakeSource("openrouter", reach: 3)
        source.unheld.withLock { $0 = ["2026-10-21"] }
        await firstPoll(makeStore(dir, [source]))
        #expect(await source.requested == [["2026-10-19", "2026-10-20"]])
        #expect(await read("2026-10-21", in: dir) == nil)

        source.unheld.withLock { $0 = [] }
        await firstPoll(makeStore(dir, [source]))
        #expect(await source.requested.last == ["2026-10-21"])
        #expect(await read("2026-10-21", in: dir)?.backfillChecked == [Self.pid("openrouter")])
    }

    @Test("a backfilled record keeps its zone; topping up an observed record does not set one (V13, V31)")
    func keepsRecordZone() async throws {
        let dir = makeDirectory()
        var utcDay = used("openrouter", tokens: 30, cost: 2)
        utcDay.timeZone = "UTC"
        var observed = DayRecord(provider: Self.pid("openrouter"), costUSD: Money(1), origin: .observed)
        observed.firstSeen = Self.at("2026-10-20T01:00:00Z")
        try writeRaw(DayFile(date: "2026-10-20", timeZone: "UTC", records: [observed]), in: dir)
        let source = FakeSource("openrouter", reach: 2, usage: ["2026-10-20": utcDay, "2026-10-21": utcDay])
        await firstPoll(makeStore(dir, [source]))

        #expect(try #require(await read("2026-10-21", in: dir)?.records.first).timeZone == "UTC")
        let toppedUp = try #require(await read("2026-10-20", in: dir)?.records.first)
        #expect(toppedUp.timeZone == nil)
        #expect(toppedUp.origin == .observed)
    }

    @Test("a failed source leaves its days unchecked and the next source still runs")
    func failureRetried() async throws {
        let dir = makeDirectory()
        let failing = FakeSource("claude", reach: 1, fails: true)
        let codex = FakeSource("codex", reach: 1)
        await firstPoll(makeStore(dir, [failing, codex]))

        #expect(await read("2026-10-21", in: dir)?.backfillChecked == [Self.pid("codex")])
        await firstPoll(makeStore(dir, [failing]))
        #expect(await failing.requested == [["2026-10-21"], ["2026-10-21"]])
    }

    @Test("sources run one at a time (V27)")
    func oneAtATime() async throws {
        let tracker = OverlapTracker()
        let sources = ["claude", "codex", "openrouter"].map { FakeSource($0, reach: 1, tracker: tracker) }
        await firstPoll(makeStore(makeDirectory(), sources))

        #expect(await tracker.maxActive == 1)
        for source in sources {
            #expect(await source.requested.count == 1)
        }
    }

    @Test("a date change seals the day and gap-fill tops it up; the new open day is never written by backfill (V27)")
    func sealTriggers() async throws {
        let dir = makeDirectory()
        let source = FakeSource("claude", reach: 1, usage: [
            "2026-10-22": used("claude", tokens: 900, cost: 6),
            "2026-10-23": used("claude", tokens: 1, cost: 1),
        ])
        let store = makeStore(dir, [source])
        await firstPoll(store, [DayRecordMergeTests.sample("claude", tokens: 300, cost: 2)])
        await store.record([], at: Self.at("2026-10-23T00:05:00Z"))
        await store.gapFillFinished()

        let sealed = try #require(await read("2026-10-22", in: dir))
        #expect(sealed.records.map(\.tokens) == [900])
        #expect(sealed.records.map(\.origin) == [.observed])
        #expect(sealed.backfillChecked == [Self.pid("claude")])
        #expect(await read("2026-10-23", in: dir) == nil)
        // Writing the open day directly is refused too.
        await store.backfill(used("claude", tokens: 1, cost: 1), on: "2026-10-23")
        #expect(await read("2026-10-23", in: dir) == nil)
    }

    @Test("nothing is written before the first poll, past retention, or into an unreadable file (V17, V18)")
    func refusals() async throws {
        let dir = makeDirectory()
        let store = makeStore(dir, [])
        await store.backfill(used("claude", tokens: 1, cost: 1), on: "2026-10-21")
        #expect(try await HistoryReader(directory: dir).dayKeys().isEmpty)

        let garbage = Data("not json".utf8)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try garbage.write(to: dir.appending(path: "2026-10-20.json"))
        await firstPoll(store)
        await store.backfill(used("claude", tokens: 1, cost: 1), on: "2026-10-20")
        await store.backfill(used("claude", tokens: 1, cost: 1), on: "2026-07-23")
        #expect(try Data(contentsOf: dir.appending(path: "2026-10-20.json")) == garbage)
        #expect(await read("2026-07-23", in: dir) == nil)
    }


    @Test("a source's account tokens land on the known account by name; others stay nil (V9, V62)")
    func accountTokensByName() async throws {
        let dir = makeDirectory()
        var usage = used("claude", tokens: 9, cost: 1)
        usage.accounts = [DayAccount(key: "work", label: "work", billingModel: .subscription, tokens: 4)]
        let accounts = ["default", "work"].map {
            UsageSnapshot.AccountUsage(name: $0, costTodayUSD: nil, quota: nil, quotaWindows: nil,
                                       accountInfo: AccountInfo(billingModel: .subscription, plan: "max"))
        }
        await firstPoll(makeStore(dir, [FakeSource("claude", reach: 1, usage: ["2026-10-21": usage], accounts: accounts)]))

        let stored = try #require(await read("2026-10-21", in: dir)?.records.first)
        #expect(stored.accounts.map(\.key) == ["default", "work"])
        #expect(stored.accounts.map(\.tokens) == [nil, 4])
    }
}

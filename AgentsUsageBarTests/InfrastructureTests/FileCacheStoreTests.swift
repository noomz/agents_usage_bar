import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("FileCacheStoreTests")
struct FileCacheStoreTests {

    // MARK: Helpers

    private func makeTempStore() throws -> FileCacheStore {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try FileCacheStore(testingRootURL: tempDir)
    }

    private func makeSampleState(id: ProviderID = .openrouter, displayName: String = "OpenRouter") -> ProviderState {
        ProviderState(
            id: id,
            displayName: displayName,
            placeholderMessage: nil,
            snapshot: nil,
            status: .unauthenticated,
            lastSuccess: nil
        )
    }

    // MARK: Tests

    @Test("fresh directory returns empty dict")
    func freshDirectoryReturnsEmptyDict() throws {
        let store = try makeTempStore()
        #expect(store.loadAll() == [:])
    }

    @Test("save then load round trips")
    func saveThenLoadRoundTrips() throws {
        let store = try makeTempStore()
        let state1 = makeSampleState(id: .openrouter, displayName: "OpenRouter")
        let state2 = makeSampleState(id: ProviderID(rawValue: "gemini"), displayName: "Gemini")
        let state3 = makeSampleState(id: ProviderID(rawValue: "ollama"), displayName: "Ollama")
        let dict: [ProviderID: ProviderState] = [
            .openrouter: state1,
            ProviderID(rawValue: "gemini"): state2,
            ProviderID(rawValue: "ollama"): state3,
        ]
        store.save(dict)
        let loaded = store.loadAll()
        #expect(loaded == dict)
    }

    @Test("load ignores schema version mismatch")
    func loadIgnoresSchemaVersionMismatch() throws {
        let store = try makeTempStore()
        // Manually write an envelope with a future schemaVersion
        let badJSON = """
        {"schemaVersion":99,"providers":{},"baselines":{}}
        """.data(using: .utf8)!
        try badJSON.write(to: store.cacheURLForTesting, options: .atomic)
        #expect(store.loadAll() == [:])
    }

    @Test("load ignores malformed JSON")
    func loadIgnoresMalformedJSON() throws {
        let store = try makeTempStore()
        let garbage = "not json".data(using: .utf8)!
        try garbage.write(to: store.cacheURLForTesting, options: .atomic)
        #expect(store.loadAll() == [:])
    }

    @Test("atomic write leaves no partial file")
    func atomicWriteLeavesNoPartialFile() throws {
        let store = try makeTempStore()
        let state = makeSampleState()
        store.save([.openrouter: state])
        // No .tmp files should remain next to the cache file
        let dir = store.cacheURLForTesting.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        let tmpFiles = contents.filter { $0.pathExtension == "tmp" }
        #expect(tmpFiles.isEmpty)
    }

    @Test("maintainBaseline cold start sets baseline to current value")
    func maintainBaselineColdStart() throws {
        let store = try makeTempStore()
        let now = Date()
        store.maintainBaseline(for: .openrouter, now: now, currentValue: 42.0)
        let record = store.baseline(for: .openrouter, on: now)
        #expect(record != nil)
        #expect(record?.value == 42.0)
        #expect(record?.lastValue == 42.0)
    }

    @Test("maintainBaseline same day keeps baseline, updates lastValue")
    func maintainBaselineSameDayKeepsBaseline() throws {
        let store = try makeTempStore()
        let now = Date()
        store.maintainBaseline(for: .openrouter, now: now, currentValue: 10.0)
        store.maintainBaseline(for: .openrouter, now: now, currentValue: 15.0)
        let record = store.baseline(for: .openrouter, on: now)
        #expect(record?.value == 10.0)   // baseline unchanged
        #expect(record?.lastValue == 15.0) // lastValue updated
    }

    @Test("maintainBaseline cross-day rolls baseline")
    func maintainBaselineCrossDayRollsBaseline() throws {
        let store = try makeTempStore()
        let day1 = Date(timeIntervalSince1970: 1_747_000_000) // arbitrary fixed date
        let day2 = Date(timeIntervalSince1970: 1_747_000_000 + 86400) // next day
        store.maintainBaseline(for: .openrouter, now: day1, currentValue: 100.0)
        store.maintainBaseline(for: .openrouter, now: day2, currentValue: 110.0)
        let record = store.baseline(for: .openrouter, on: day2)
        // Baseline should have reset to current value on new day
        #expect(record?.value == 110.0)
    }

    @Test("maintainBaseline negative delta resets baseline")
    func maintainBaselineNegativeDeltaResetsAndLogs() throws {
        let store = try makeTempStore()
        let now = Date()
        store.maintainBaseline(for: .openrouter, now: now, currentValue: 50.0)
        // Simulate refund: currentValue drops below baseline
        store.maintainBaseline(for: .openrouter, now: now, currentValue: 30.0)
        let record = store.baseline(for: .openrouter, on: now)
        #expect(record?.value == 30.0) // reset to current
    }

    // MARK: Daily usage accumulator (delta → cumulative)

    @Test("accumulateDailyUsage sums same-day poll deltas")
    func accumulateDailyUsageSumsSameDayDeltas() throws {
        let store = try makeTempStore()
        let now = Date()

        // Poll 1: first read of the day (e.g. whole-day delta on cold cache).
        let p1 = store.accumulateDailyUsage(for: .claude, now: now, deltaTokens: 100, deltaCostUSD: Decimal(string: "0.01")!)
        #expect(p1.tokens == 100)
        #expect(p1.costUSD == Decimal(string: "0.01")!)

        // Poll 2: only the new delta since poll 1 — must ADD, not replace.
        let p2 = store.accumulateDailyUsage(for: .claude, now: now, deltaTokens: 50, deltaCostUSD: Decimal(string: "0.02")!)
        #expect(p2.tokens == 150)
        #expect(p2.costUSD == Decimal(string: "0.03")!)

        // Poll 3: an idle interval (zero delta) keeps the running total — does NOT reset to 0.
        let p3 = store.accumulateDailyUsage(for: .claude, now: now, deltaTokens: 0, deltaCostUSD: 0)
        #expect(p3.tokens == 150)
        #expect(p3.costUSD == Decimal(string: "0.03")!)
    }

    @Test("accumulateDailyUsage resets at local-midnight rollover")
    func accumulateDailyUsageResetsOnNewDay() throws {
        let store = try makeTempStore()
        let day1 = Date(timeIntervalSince1970: 1_747_000_000)
        let day2 = Date(timeIntervalSince1970: 1_747_000_000 + 86_400) // next calendar day

        _ = store.accumulateDailyUsage(for: .claude, now: day1, deltaTokens: 900, deltaCostUSD: Decimal(string: "0.50")!)
        let next = store.accumulateDailyUsage(for: .claude, now: day1, deltaTokens: 100, deltaCostUSD: Decimal(string: "0.10")!)
        #expect(next.tokens == 1000) // same day accumulates

        // New day → reset to that day's first delta, not day1's 1000.
        let rolled = store.accumulateDailyUsage(for: .claude, now: day2, deltaTokens: 42, deltaCostUSD: Decimal(string: "0.05")!)
        #expect(rolled.tokens == 42)
        #expect(rolled.costUSD == Decimal(string: "0.05")!)
    }

    @Test("accumulateDailyUsage persists the running total across store instances")
    func accumulateDailyUsagePersistsAcrossRelaunch() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let now = Date()

        let store1 = try FileCacheStore(testingRootURL: tempDir)
        _ = store1.accumulateDailyUsage(for: .claude, now: now, deltaTokens: 200, deltaCostUSD: Decimal(string: "0.20")!)

        // Simulate app relaunch: a fresh store over the same on-disk file.
        let store2 = try FileCacheStore(testingRootURL: tempDir)
        let resumed = store2.accumulateDailyUsage(for: .claude, now: now, deltaTokens: 55, deltaCostUSD: Decimal(string: "0.05")!)
        #expect(resumed.tokens == 255) // continues from the persisted 200
        #expect(resumed.costUSD == Decimal(string: "0.25")!)
    }

    @Test("accumulateDailyUsage isolates providers")
    func accumulateDailyUsageIsolatesProviders() throws {
        let store = try makeTempStore()
        let now = Date()
        _ = store.accumulateDailyUsage(for: .claude, now: now, deltaTokens: 100, deltaCostUSD: Decimal(string: "0.01")!)
        let codex = store.accumulateDailyUsage(for: ProviderID(rawValue: "codex"), now: now, deltaTokens: 7, deltaCostUSD: Decimal(string: "0.02")!)
        #expect(codex.tokens == 7) // independent of claude's 100
    }
}

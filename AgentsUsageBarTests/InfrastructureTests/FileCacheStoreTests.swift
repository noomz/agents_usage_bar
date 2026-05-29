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
}

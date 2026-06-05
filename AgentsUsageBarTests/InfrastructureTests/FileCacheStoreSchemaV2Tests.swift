import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("FileCacheStore schemaVersion 2 — transcript offsets + v1→v2 migration")
struct FileCacheStoreSchemaV2Tests {

    // MARK: - Helpers

    private func makeTempCache() throws -> FileCacheStore {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try FileCacheStore(testingRootURL: tempDir)
    }

    private func makeOffset(url: String = "file:///tmp/test.jsonl", byteOffset: UInt64 = 0) -> TranscriptOffset {
        TranscriptOffset(url: url, byteOffset: byteOffset, lastModified: Date())
    }

    // MARK: - Tests

    @Test func freshStore_emptyTranscripts() throws {
        let store = try makeTempCache()
        #expect(store.allTranscriptOffsets() == [:])
    }

    @Test func setOffset_thenRead_returnsSameOffset() throws {
        let store = try makeTempCache()
        let off = makeOffset(url: "file:///tmp/a.jsonl", byteOffset: 1234)
        store.setTranscriptOffset(off)
        let retrieved = try #require(store.transcriptOffset(forURL: off.url))
        #expect(retrieved.url == off.url)
        #expect(retrieved.byteOffset == off.byteOffset)
    }

    @Test func setMultipleOffsets_allReturned() throws {
        let store = try makeTempCache()
        store.setTranscriptOffset(makeOffset(url: "file:///tmp/a.jsonl", byteOffset: 100))
        store.setTranscriptOffset(makeOffset(url: "file:///tmp/b.jsonl", byteOffset: 200))
        store.setTranscriptOffset(makeOffset(url: "file:///tmp/c.jsonl", byteOffset: 300))
        #expect(store.allTranscriptOffsets().count == 3)
    }

    @Test func overwriteOffset_keepsLatest() throws {
        let store = try makeTempCache()
        let url = "file:///tmp/x.jsonl"
        store.setTranscriptOffset(makeOffset(url: url, byteOffset: 100))
        store.setTranscriptOffset(makeOffset(url: url, byteOffset: 500))
        let retrieved = try #require(store.transcriptOffset(forURL: url))
        #expect(retrieved.byteOffset == 500)
    }

    @Test func unknownURL_returnsNil() throws {
        let store = try makeTempCache()
        #expect(store.transcriptOffset(forURL: "file:///nonexistent") == nil)
    }

    @Test func v1_envelope_on_disk_migrates_preserving_baselines() throws {
        let store = try makeTempCache()

        // Strategy: write a real v2 envelope via FileCacheStore (so the on-disk
        // shape matches Swift's actual encoder output for [ProviderID: T] —
        // a JSON array of alternating key/value entries, not a JSON object —
        // see RESEARCH §A schemaVersion bump risk). Then mutate the on-disk file
        // back to v1 by flipping `schemaVersion` to 1 and stripping `transcripts`.
        // This is a faithful Phase 1 disk artifact: same byte shape Phase 1
        // would have written before schema v2 existed.
        let now = Date()
        store.maintainBaseline(for: .openrouter, now: now, currentValue: 50.0)

        let v2Data = try Data(contentsOf: store.cacheURLForTesting)
        var v2JSON = try #require(try JSONSerialization.jsonObject(with: v2Data) as? [String: Any])
        v2JSON["schemaVersion"] = 1
        v2JSON.removeValue(forKey: "transcripts")
        let v1Data = try JSONSerialization.data(withJSONObject: v2JSON, options: [])
        try v1Data.write(to: store.cacheURLForTesting, options: .atomic)

        // loadAll() should preserve baselines — NOT cold-start.
        let providers = store.loadAll()
        #expect(providers.isEmpty) // providers was empty in v1

        let baseline = store.baseline(for: .openrouter, on: now)
        #expect(baseline != nil)
        #expect(baseline?.value == 50.0)

        // allTranscriptOffsets() should return empty (migrated v1 had none).
        #expect(store.allTranscriptOffsets() == [:])

        // After any write, the file should be the current schemaVersion (3 since
        // the dailyUsage accumulator was added; a v1 disk artifact migrates straight
        // through to v3 on the next write).
        // Trigger a write by setting a transcript offset.
        store.setTranscriptOffset(makeOffset(url: "file:///tmp/a.jsonl", byteOffset: 0))

        let rawData = try Data(contentsOf: store.cacheURLForTesting)
        let json = try #require(try? JSONSerialization.jsonObject(with: rawData) as? [String: Any])
        let version = try #require(json["schemaVersion"] as? Int)
        #expect(version == 3)

        // Baselines must still be present after the write.
        // Swift encodes [ProviderID: BaselineRecord] as a JSON array of alternating
        // key/value entries — non-empty array means baselines survived migration.
        let baselinesArray = try #require(json["baselines"] as? [Any])
        #expect(!baselinesArray.isEmpty)
    }

    @Test func setting_offset_does_not_clobber_baselines() throws {
        let store = try makeTempCache()

        // Establish a baseline first.
        let now = Date()
        store.maintainBaseline(for: .openrouter, now: now, currentValue: 75.0)

        // Set a transcript offset.
        store.setTranscriptOffset(makeOffset(url: "file:///tmp/b.jsonl", byteOffset: 42))

        // Baseline must still be readable.
        let record = store.baseline(for: .openrouter, on: now)
        #expect(record?.value == 75.0)
    }

    @Test func setting_baseline_does_not_clobber_transcripts() throws {
        let store = try makeTempCache()

        // Set a transcript offset first.
        let off = makeOffset(url: "file:///tmp/c.jsonl", byteOffset: 999)
        store.setTranscriptOffset(off)

        // Maintain baseline (triggers a write).
        store.maintainBaseline(for: .openrouter, now: Date(), currentValue: 10.0)

        // Transcript offset must still be present.
        let retrieved = store.transcriptOffset(forURL: off.url)
        #expect(retrieved?.byteOffset == 999)
    }

    @Test func corrupt_envelope_cold_starts_without_throwing() throws {
        let store = try makeTempCache()
        try "this is not json".data(using: .utf8)!.write(to: store.cacheURLForTesting, options: .atomic)
        #expect(store.loadAll() == [:])
        #expect(store.allTranscriptOffsets() == [:])
    }

    @Test func concurrent_set_offsets_serialize_correctly() async throws {
        let store = try makeTempCache()

        // Fan out 50 setTranscriptOffset calls concurrently.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let off = TranscriptOffset(
                        url: "file:///tmp/file-\(i).jsonl",
                        byteOffset: UInt64(i * 10),
                        lastModified: Date()
                    )
                    store.setTranscriptOffset(off)
                }
            }
        }

        // All 50 unique URLs must be present — proves .barrier serialized the writes.
        #expect(store.allTranscriptOffsets().count == 50)
    }
}

import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("ClaudeSwitchableProvider")
struct ClaudeSwitchableProviderTests {

    // MARK: - Source box (mutable @Sendable selector for delegation tests)

    /// A tiny mutable box so a single facade's `@Sendable` source closure can be flipped
    /// between fetches. `@unchecked Sendable` is safe here — the test drives all reads and
    /// writes serially on one task.
    private final class SourceBox: @unchecked Sendable {
        var value: ClaudeUsageSource
        init(_ value: ClaudeUsageSource) { self.value = value }
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeSession(_ name: String, json: String, mtime: Date, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("\(name).json")
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    /// A JSONL provider over an empty roots directory — returns a valid snapshot with a
    /// non-nil (zero) `tokensToday` and no quota. This is distinguishable from the hook
    /// provider, whose `tokensToday` is always nil.
    private func makeJSONLProvider(rootsEmptyDir: URL) -> ClaudeJSONLProvider {
        let pricing = ClaudeModelPricing(
            schemaVersion: 1,
            lastUpdated: "test",
            default: .init(inputPer1M: 3.0, outputPer1M: 15.0, cacheWritePer1M: 3.75, cacheReadPer1M: 0.30),
            models: [:]
        )
        return ClaudeJSONLProvider(
            reader: TranscriptReader(),
            scanner: TranscriptDirectoryScanner(),
            pricing: pricing,
            oauth: nil,
            cache: NoopCacheStore(),
            clock: SystemClock(),
            roots: [rootsEmptyDir]
        )
    }

    // MARK: - Delegation

    @Test func hookSourceDelegatesToHookProvider() async throws {
        let hookDir = try makeTempDir()
        let jsonlRoots = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: hookDir)
            try? FileManager.default.removeItem(at: jsonlRoots)
        }

        let now = Date()
        try writeSession("s1", json: #"{ "session_id": "s1", "cost": { "total_cost_usd": 3.5 } }"#,
                         mtime: now, in: hookDir)

        let facade = ClaudeSwitchableProvider(
            jsonl: makeJSONLProvider(rootsEmptyDir: jsonlRoots),
            hookProvider: ClaudeHookProvider(feedDir: hookDir),
            source: { .hook }
        )

        let snap = try await facade.fetch(now: now)
        // Hook fingerprint: cost from feed, tokens always nil.
        #expect(snap.costTodayUSD == Decimal(string: "3.5"))
        #expect(snap.tokensToday == nil)
        #expect(snap.providerID == .claude)
    }

    @Test func sessionReadsSourceDelegatesToJSONLProvider() async throws {
        let hookDir = try makeTempDir()
        let jsonlRoots = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: hookDir)
            try? FileManager.default.removeItem(at: jsonlRoots)
        }

        let now = Date()
        // Hook feed has data too — but sessionReads must ignore it entirely.
        try writeSession("s1", json: #"{ "session_id": "s1", "cost": { "total_cost_usd": 3.5 } }"#,
                         mtime: now, in: hookDir)

        let facade = ClaudeSwitchableProvider(
            jsonl: makeJSONLProvider(rootsEmptyDir: jsonlRoots),
            hookProvider: ClaudeHookProvider(feedDir: hookDir),
            source: { .sessionReads }
        )

        let snap = try await facade.fetch(now: now)
        // JSONL fingerprint: tokensToday is a number (0 over an empty root), never nil.
        #expect(snap.tokensToday == 0)
        #expect(snap.costTodayUSD != Decimal(string: "3.5"))
        #expect(snap.providerID == .claude)
    }

    @Test func flippingSourceFlipsDelegation() async throws {
        let hookDir = try makeTempDir()
        let jsonlRoots = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: hookDir)
            try? FileManager.default.removeItem(at: jsonlRoots)
        }

        let now = Date()
        try writeSession("s1", json: #"{ "session_id": "s1", "cost": { "total_cost_usd": 7.25 } }"#,
                         mtime: now, in: hookDir)

        let box = SourceBox(.sessionReads)
        let facade = ClaudeSwitchableProvider(
            jsonl: makeJSONLProvider(rootsEmptyDir: jsonlRoots),
            hookProvider: ClaudeHookProvider(feedDir: hookDir),
            source: { box.value }
        )

        // sessionReads first.
        let first = try await facade.fetch(now: now)
        #expect(first.tokensToday == 0)

        // Flip to hook; same facade instance now delegates to the hook provider.
        box.value = .hook
        let second = try await facade.fetch(now: now)
        #expect(second.tokensToday == nil)
        #expect(second.costTodayUSD == Decimal(string: "7.25"))
    }

    // MARK: - Status mirroring

    @Test func statusMirrorsDelegateOnSuccess() async throws {
        let hookDir = try makeTempDir()
        let jsonlRoots = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: hookDir)
            try? FileManager.default.removeItem(at: jsonlRoots)
        }

        let now = Date()
        try writeSession("s1", json: #"{ "session_id": "s1", "cost": { "total_cost_usd": 1.0 } }"#,
                         mtime: now, in: hookDir)

        let facade = ClaudeSwitchableProvider(
            jsonl: makeJSONLProvider(rootsEmptyDir: jsonlRoots),
            hookProvider: ClaudeHookProvider(feedDir: hookDir),
            source: { .hook }
        )

        _ = try await facade.fetch(now: now)
        #expect(await facade.status() == .ok(lastSuccess: now))
    }

    @Test func statusMirrorsDelegateOnError() async throws {
        // Empty hook feed → hook provider throws → facade mirrors the delegate's error status.
        let hookDir = try makeTempDir()
        let jsonlRoots = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: hookDir)
            try? FileManager.default.removeItem(at: jsonlRoots)
        }

        let facade = ClaudeSwitchableProvider(
            jsonl: makeJSONLProvider(rootsEmptyDir: jsonlRoots),
            hookProvider: ClaudeHookProvider(feedDir: hookDir),
            source: { .hook }
        )

        await #expect(throws: ClaudeHookError.noFeedData) {
            _ = try await facade.fetch(now: Date())
        }

        // Facade status is an error (mirrors the hook delegate's post-throw status).
        let status = await facade.status()
        if case .error = status {
            // expected
        } else {
            Issue.record("expected .error status, got \(status)")
        }
    }
}

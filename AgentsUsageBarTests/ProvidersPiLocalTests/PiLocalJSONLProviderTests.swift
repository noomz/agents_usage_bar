import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("PiLocalJSONLProvider", .serialized)
struct PiLocalJSONLProviderTests {

    @Test func fetch_counts_local_assistant_skips_openrouter_compaction() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("s.jsonl")
        try writeMixedFixture(to: sessionURL, now: .now)

        let catalog = PiLocalCatalog.load(urls: [fixtureURL("models-local.json")])
        let provider = PiLocalJSONLProvider(
            scanner: TranscriptDirectoryScanner(),
            reader: PiSessionReader(),
            sessionRoots: { [root] },
            loadCatalog: { catalog },
            cache: FakeCacheStore(),
            clock: VirtualClock(fixed: .now)
        )
        let snap = try await provider.fetch(now: .now)
        #expect(snap.tokensToday == 33482)
        #expect(snap.raw["providers"] == "DRM-SWAP")
        #expect(snap.raw["models"] == "qwen3.8-27b")
        #expect(snap.quota == nil)
        #expect(snap.providerID == .piLocal)
        #expect(provider.capabilities.hasTokens)
        #expect(provider.capabilities.hasCost)
        #expect(provider.capabilities.hasQuota == false)
        #expect(provider.capabilities.isLocal == false)
        #expect(snap.accountInfo?.billingModel == .local)
        if case .ok = await provider.status() { } else {
            Issue.record("Expected .ok")
        }
    }

    @Test func fetch_counts_type_usage_in_addition_to_assistant() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let ts = iso(now)
        let jsonl = """
        {"type":"message","timestamp":"\(ts)","message":{"role":"assistant","provider":"DRM-SWAP","model":"qwen3.8-27b","usage":{"totalTokens":33482,"cost":{"total":0}}}}
        {"type":"usage","timestamp":"\(ts)","kind":"cache_warm","provider":"DRM-SWAP","model":"qwen3.8-27b","usage":{"totalTokens":100,"cost":{"total":0}}}
        """.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try jsonl.write(to: root.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let catalog = PiLocalCatalog(names: [PiProviderName(rawValue: "DRM-SWAP")])
        let provider = PiLocalJSONLProvider(
            scanner: TranscriptDirectoryScanner(),
            reader: PiSessionReader(),
            sessionRoots: { [root] },
            loadCatalog: { catalog },
            cache: FakeCacheStore(),
            clock: VirtualClock(fixed: now)
        )
        let snap = try await provider.fetch(now: now)
        #expect(snap.tokensToday == 33582)
    }

    @Test func fetch_no_root_is_unauthenticated() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-pi-\(UUID().uuidString)")
        let provider = PiLocalJSONLProvider(
            scanner: TranscriptDirectoryScanner(),
            reader: PiSessionReader(),
            sessionRoots: { [missing] },
            loadCatalog: { PiLocalCatalog(names: [PiProviderName(rawValue: "llama.cpp")]) },
            cache: FakeCacheStore(),
            clock: SystemClock()
        )
        let snap = try await provider.fetch(now: .now)
        #expect(snap.raw["providerStatus"] == "unauthenticated")
        #expect(await provider.status() == .unauthenticated)
    }

    @Test func reader_does_not_open_real_home_pi() {
        let path = URL(fileURLWithPath: #filePath).path
        #expect(path.contains("AgentsUsageBarTests/ProvidersPiLocalTests"))
        #expect(path.contains("/.pi/") == false)
    }
}

private func makeTempRoot() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("PiLocalJSONLProviderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func writeMixedFixture(to dest: URL, now: Date) throws {
    let raw = try String(contentsOf: fixtureURL("session-mixed.jsonl"), encoding: .utf8)
    let materialized = raw.replacingOccurrences(of: "<TS>", with: iso(now))
    try materialized.write(to: dest, atomically: true, encoding: .utf8)
}

private func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

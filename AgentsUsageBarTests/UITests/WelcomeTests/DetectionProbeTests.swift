import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - DetectionProbeTests
//
// Tests for DetectionProbe.probeAll — 7 providers, parallel detection.
// Uses URLProtocol stubs for HTTP probes and temporary directories for FS probes.
//
// Serialized because StubURLProtocol uses shared static state.
@Suite("DetectionProbeTests", .serialized)
struct DetectionProbeTests {

    // MARK: - OpenRouter

    @Test func openrouter_detected_whenApiKeyPresent() async {
        let config = makeConfig(openrouterKey: Secret("test-key"))
        let http = makeStubHTTP(status: 200)
        let results = await DetectionProbe.probeAll(config: config, localhostHTTP: http)
        #expect(results[.openrouter] == .detected)
    }

    @Test func openrouter_notConfigured_whenApiKeyAbsent() async {
        let config = makeConfig(openrouterKey: nil)
        let http = makeStubHTTP(status: 200)
        let results = await DetectionProbe.probeAll(config: config, localhostHTTP: http)
        #expect(results[.openrouter] == .notConfigured)
    }

    // MARK: - Claude

    @Test func claude_detected_whenProjectsDirExists() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        // Create ~/.claude/projects equivalent in temp dir
        let claudeDir = tmpDir.appendingPathComponent(".claude/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let fm = FakeHomeFileManager(homeDir: tmpDir)
        let config = makeConfig(openrouterKey: nil)
        let http = makeStubHTTP(status: 500)
        let results = await DetectionProbe.probeAll(config: config, localhostHTTP: http, fileManager: fm)
        #expect(results[.claude] == .detected)
    }

    // MARK: - Codex

    @Test func codex_detected_whenSessionsDirExists() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let codexDir = tmpDir.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let fm = FakeHomeFileManager(homeDir: tmpDir)
        let config = makeConfig(openrouterKey: nil)
        let http = makeStubHTTP(status: 500)
        let results = await DetectionProbe.probeAll(config: config, localhostHTTP: http, fileManager: fm)
        #expect(results[.codex] == .detected)
    }

    // MARK: - Gemini

    @Test func gemini_detected_whenCredsAndSettingsPresent() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let geminiDir = tmpDir.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        // Write oauth_creds.json
        let credsPath = geminiDir.appendingPathComponent("oauth_creds.json")
        try Data("{}".utf8).write(to: credsPath)
        // Write settings.json with nested oauth-personal (RESEARCH correction #2)
        let settings = """
        {"security":{"auth":{"selectedType":"oauth-personal"}}}
        """
        let settingsPath = geminiDir.appendingPathComponent("settings.json")
        try Data(settings.utf8).write(to: settingsPath)
        let fm = FakeHomeFileManager(homeDir: tmpDir)
        let config = makeConfig(openrouterKey: nil)
        let http = makeStubHTTP(status: 500)
        let results = await DetectionProbe.probeAll(config: config, localhostHTTP: http, fileManager: fm)
        #expect(results[.gemini] == .detected)
    }

    // MARK: - Ollama HTTP probes

    @Test func ollama_detected_whenHTTPReturns200() async {
        StubURLProtocol.stub = { _ in
            (Data("{}".utf8), makeHTTPResponse(status: 200, url: URL(string: "http://localhost:11434/api/version")!))
        }
        defer { StubURLProtocol.stub = nil }
        let config = makeConfig(openrouterKey: nil)
        let http = makeStubHTTPClient()
        let results = await DetectionProbe.probeAll(config: config, localhostHTTP: http)
        #expect(results[.ollama] == .detected)
    }

    @Test func ollama_notRunning_whenConnectionRefused() async {
        StubURLProtocol.stub = { _ in
            // Return a server error to simulate connection refused
            (Data(), makeHTTPResponse(status: 503, url: URL(string: "http://localhost:11434/api/version")!))
        }
        defer { StubURLProtocol.stub = nil }
        let config = makeConfig(openrouterKey: nil)
        let http = makeStubHTTPClient()
        let results = await DetectionProbe.probeAll(config: config, localhostHTTP: http)
        // 503 is a non-2xx response → HTTPError thrown → .notRunning
        #expect(results[.ollama] == .notRunning)
    }

    // MARK: - llama.cpp

    @Test func llamacpp_notConfigured_whenPortAbsent() async {
        let config = makeConfig(openrouterKey: nil, llamacppPort: nil)
        let http = makeStubHTTP(status: 200)
        let results = await DetectionProbe.probeAll(config: config, localhostHTTP: http)
        #expect(results[.llamacpp] == .notConfigured)
    }

    // MARK: - All 7 providers present

    @Test func probeAll_runsAllSevenProviders() async {
        let config = makeConfig(openrouterKey: nil)
        let http = makeStubHTTP(status: 200)
        let results = await DetectionProbe.probeAll(config: config, localhostHTTP: http)
        #expect(results.count == 7)
        for id in ProviderID.allKnown {
            #expect(results[id] != nil, "Missing result for \(id.rawValue)")
        }
    }

    // MARK: - CFG-06 source walk

    @Test func cfg06_noShellRcReferences_inDetectionProbe() throws {
        // Source-walk DetectionProbe.swift and assert no shell RC file paths
        // Note: comment-level documentation is excluded; this test reads the actual
        // source file and checks that no runtime string literals reference RC files.
        // We check the source for runtime-path patterns (not doc comments).
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WelcomeTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // AgentsUsageBarTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("AgentsUsageBar/UI/Welcome/DetectionProbe.swift")
        let source = try String(contentsOf: sourceURL)
        // Check that no actual path string literals reference shell RC files
        // (grep for quoted strings containing these paths)
        #expect(!source.contains("\"/.zshrc\""), "DetectionProbe must not read .zshrc")
        #expect(!source.contains("\"/.bashrc\""), "DetectionProbe must not read .bashrc")
        #expect(!source.contains("\"config.fish\""), "DetectionProbe must not read config.fish")
    }
}

// MARK: - Test helpers

/// Creates an `AppConfig` with injectable key fields for detection testing.
private func makeConfig(
    openrouterKey: Secret?,
    lmstudioPort: Int = 1234,
    llamacppPort: Int? = nil
) -> AppConfig {
    AppConfig(
        refreshInterval: .m5,
        threshold: 0.80,
        openrouter: OpenRouterConfig(
            apiKey: openrouterKey,
            apiURL: URL(string: "https://openrouter.ai/api/v1")!,
            httpReferer: nil,
            xTitle: "Test",
            enabled: true
        ),
        codex: CodexConfig(enabled: true, bearerOverride: nil, sessionWindowDays: 2),
        gemini: GeminiConfig(enabled: true, projectIDOverride: nil),
        ollama: OllamaConfig(enabled: true),
        lmstudio: LMStudioConfig(enabled: true, port: lmstudioPort),
        llamacpp: LlamaCppConfig(enabled: true, port: llamacppPort)
    )
}

/// Creates a simple `URLSessionHTTPClient` backed by `StubURLProtocol` with a fixed status.
private func makeStubHTTP(status: Int) -> URLSessionHTTPClient {
    StubURLProtocol.stub = { req in
        (Data("{}".utf8), makeHTTPResponse(status: status, url: req.url!))
    }
    return makeStubHTTPClient()
}

private func makeStubHTTPClient() -> URLSessionHTTPClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: cfg)
    return URLSessionHTTPClient(session: session)
}

private func makeHTTPResponse(status: Int, url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

private func makeTempDir() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("DetectionProbeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

// MARK: - FakeHomeFileManager

/// FileManager subclass that redirects `homeDirectoryForCurrentUser` to an injected temp URL.
/// Used to isolate FS probe tests from the real home directory.
final class FakeHomeFileManager: FileManager, @unchecked Sendable {
    private let homeDir: URL
    init(homeDir: URL) { self.homeDir = homeDir }
    override var homeDirectoryForCurrentUser: URL { homeDir }
}

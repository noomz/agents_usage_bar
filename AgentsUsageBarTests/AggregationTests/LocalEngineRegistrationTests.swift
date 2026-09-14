import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("LocalEngineRegistrationTests")
struct LocalEngineRegistrationTests {

    @MainActor
    @Test func factory_registersLmstudioLlamaCppWhenProcessMatches() {
        let catalog = StaticProcessCatalog([
            RunningProcess(
                pid: 42,
                executablePath: "/Users/me/.lmstudio/extensions/backends/llama.cpp-mac-arm64/llama-server",
                arguments: ["llama-server", "-m", "qwen.gguf", "--port", "8123"]
            )
        ])
        let built = ProviderRegistryFactory.build(
            config: AppConfig.defaults,
            preferences: UserPreferencesStore(defaults: UserDefaults(suiteName: "test-eng-\(UUID().uuidString)")!),
            http: URLSessionHTTPClient(),
            localhostHTTP: URLSessionHTTPClient(timeoutSeconds: 2),
            cache: NoopCacheStore(),
            clock: SystemClock(),
            processCatalog: catalog
        )
        #expect(built.providers.contains(where: { $0.id == .lmstudioLlamaCpp }))
        #expect(built.providers.contains(where: { $0.id == .llamacpp }) == false)
    }

    @MainActor
    @Test func factory_seedsPlaceholderWhenNoMatch() {
        let built = ProviderRegistryFactory.build(
            config: AppConfig.defaults,
            preferences: UserPreferencesStore(defaults: UserDefaults(suiteName: "test-eng-\(UUID().uuidString)")!),
            http: URLSessionHTTPClient(),
            localhostHTTP: URLSessionHTTPClient(timeoutSeconds: 2),
            cache: NoopCacheStore(),
            clock: SystemClock(),
            processCatalog: StaticProcessCatalog()
        )
        #expect(built.providers.contains(where: { $0.id == .lmstudioLlamaCpp }) == false)
        let seed = built.placeholders.first { $0.providerID == .lmstudioLlamaCpp }
        #expect(seed != nil)
        #expect(seed?.status == .notRunning)
        #expect(seed?.displayName == "LM Studio llama.cpp")
    }

    @MainActor
    @Test func factory_registersCustomEngineOnExplicitPort() {
        var config = AppConfig.defaults
        config = AppConfig(
            refreshInterval: config.refreshInterval,
            threshold: config.threshold,
            openrouter: config.openrouter,
            codex: config.codex,
            gemini: config.gemini,
            grok: config.grok,
            ollama: config.ollama,
            lmstudio: config.lmstudio,
            llamacpp: config.llamacpp,
            engines: config.engines + [
                LocalEngineConfig(
                    id: ProviderID(rawValue: "engine.classifier"),
                    displayName: "DRM classifier",
                    enabled: true,
                    kind: .llamacpp,
                    matchPath: nil,
                    port: 8123
                )
            ]
        )
        let built = ProviderRegistryFactory.build(
            config: config,
            preferences: UserPreferencesStore(defaults: UserDefaults(suiteName: "test-eng-\(UUID().uuidString)")!),
            http: URLSessionHTTPClient(),
            localhostHTTP: URLSessionHTTPClient(timeoutSeconds: 2),
            cache: NoopCacheStore(),
            clock: SystemClock(),
            processCatalog: StaticProcessCatalog()
        )
        #expect(built.providers.contains(where: { $0.id.rawValue == "engine.classifier" }))
        #expect(built.providers.first(where: { $0.id.rawValue == "engine.classifier" })?.displayName
            == "DRM classifier")
    }

    @MainActor
    @Test func parameterizedLlamaCppProvider_usesInjectedID() async throws {
        let http = FakeLlamaCppHTTPClient()
        http.responses = [
            "/health": [.success(Data("{\"status\":\"ok\"}".utf8))],
            "/v1/models": [.success(Data("{\"data\":[]}".utf8))]
        ]
        let provider = LlamaCppProvider(
            http: http,
            clock: SystemClock(),
            port: 8123,
            id: .lmstudioLlamaCpp,
            displayName: "LM Studio llama.cpp"
        )
        #expect(provider.id == .lmstudioLlamaCpp)
        #expect(provider.displayName == "LM Studio llama.cpp")
        let snap = try await provider.fetch(now: Date())
        #expect(snap.providerID == .lmstudioLlamaCpp)
    }
}

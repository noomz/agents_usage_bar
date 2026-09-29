import Foundation
import Testing
@testable import AgentsUsageBar

// SPEC V1/V2/V8/V15 — Ollama Cloud config keys live in [ollama]; api key env > toml.
// Keys here are fake placeholders, never real credentials.

@Suite("ConfigStoreOllamaCloudTests")
struct ConfigStoreOllamaCloudTests {

    private func load(toml: String?, env: [String: String] = [:]) throws -> AppConfig {
        var path = FileManager.default.temporaryDirectory
            .appending(path: "ConfigStoreOllamaCloudTests-\(UUID().uuidString)")
        if let toml {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data(toml.utf8).write(to: path.appending(path: "config.toml"))
        }
        path = path.appending(path: "config.toml")
        return ConfigStore(env: DictionaryEnvReader(env), tomlPath: path).load()
    }

    @Test func defaults_enabledNoKeyNoBillingDay() throws {
        let cloud = try load(toml: nil).ollamaCloud
        #expect(cloud.enabled == true)
        #expect(cloud.apiKey == nil)
        #expect(cloud.apiKeySource == nil)
        #expect(cloud.billingDay == nil)
    }

    @Test func envKey_sourceEnv() throws {
        let cloud = try load(toml: nil, env: ["OLLAMA_API_KEY": "fake-ollama-env"]).ollamaCloud
        #expect(cloud.apiKey?.revealForRequest() == "fake-ollama-env")
        #expect(cloud.apiKeySource == .env)
    }

    @Test func tomlKey_sourceConfig() throws {
        let cloud = try load(toml: "[ollama]\napi_key = \"fake-ollama-toml\"\n").ollamaCloud
        #expect(cloud.apiKey?.revealForRequest() == "fake-ollama-toml")
        #expect(cloud.apiKeySource == .config)
    }

    @Test func envBeatsToml() throws {
        let cloud = try load(
            toml: "[ollama]\napi_key = \"fake-ollama-toml\"\n",
            env: ["OLLAMA_API_KEY": "fake-ollama-env"]
        ).ollamaCloud
        #expect(cloud.apiKey?.revealForRequest() == "fake-ollama-env")
        #expect(cloud.apiKeySource == .env)
    }

    @Test func emptyKeys_treatedAsAbsent() throws {
        let cloud = try load(toml: "[ollama]\napi_key = \"\"\n", env: ["OLLAMA_API_KEY": ""]).ollamaCloud
        #expect(cloud.apiKey == nil)
        #expect(cloud.apiKeySource == nil)
    }

    @Test func cloudFalse_disablesCloudOnly() throws {
        let config = try load(toml: "[ollama]\ncloud = false\n")
        #expect(config.ollamaCloud.enabled == false)
        #expect(config.ollama.enabled == true)
    }

    @Test func ollamaEnabledFalse_leavesCloudEnabled() throws {
        let config = try load(toml: "[ollama]\nenabled = false\n")
        #expect(config.ollama.enabled == false)
        #expect(config.ollamaCloud.enabled == true)
    }

    @Test(arguments: [(1, 1 as Int?), (15, 15), (31, 31), (0, nil), (32, nil), (-3, nil)])
    func billingDay_rangeChecked(value: Int, expected: Int?) throws {
        let cloud = try load(toml: "[ollama]\nbilling_day = \(value)\n").ollamaCloud
        #expect(cloud.billingDay == expected)
    }

    @Test func billingDay_nonInteger_ignored() throws {
        let cloud = try load(toml: "[ollama]\nbilling_day = \"15\"\n").ollamaCloud
        #expect(cloud.billingDay == nil)
    }

    @Test func secretRedactedInDescription() throws {
        let cloud = try load(toml: nil, env: ["OLLAMA_API_KEY": "fake-ollama-env"]).ollamaCloud
        #expect(!String(describing: cloud).contains("fake-ollama-env"))
    }

    // MARK: - ProviderID (V12, V15)

    @Test func providerID_placedAfterOllama_remote() {
        let all = ProviderID.allKnown
        let ollama = try! #require(all.firstIndex(of: .ollama))
        #expect(all[ollama + 1] == .ollamaCloud)
        #expect(ProviderID.ollamaCloud.rawValue == "ollama-cloud")
        #expect(ProviderID.ollamaCloud.displayHint == "Ollama Cloud")
        #expect(ProviderID.ollamaCloud.isLocalRuntime == false)
    }
}

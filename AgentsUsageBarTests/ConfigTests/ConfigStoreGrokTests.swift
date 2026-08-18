import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("ConfigStoreGrokTests")
struct ConfigStoreGrokTests {

    @Test func toml_enabled_false_and_api_url() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let toml = dir.appending(path: "config.toml")
        try Data("""
        [grok]
        enabled = false
        api_url = "https://proxy.example.test/v1"
        """.utf8).write(to: toml)
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: toml)
        let config = store.load()
        #expect(config.grok.enabled == false)
        #expect(config.grok.apiURL.absoluteString == "https://proxy.example.test/v1")
        #expect(config.grok.apiKey == nil)
    }

    @Test func env_api_key_and_base_url_win() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let toml = dir.appending(path: "config.toml")
        try Data("""
        [grok]
        api_url = "https://from-toml.test/v1"
        """.utf8).write(to: toml)
        let store = ConfigStore(
            env: DictionaryEnvReader([
                "XAI_API_KEY": "fake-xai-from-env",
                "GROK_CLI_CHAT_PROXY_BASE_URL": "https://from-env.test/v1",
            ]),
            tomlPath: toml
        )
        let config = store.load()
        #expect(config.grok.apiKey?.revealForRequest() == "fake-xai-from-env")
        #expect(config.grok.apiURL.absoluteString == "https://from-env.test/v1")
    }

    @Test func empty_xai_api_key_treated_as_absent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let toml = dir.appending(path: "config.toml")
        try Data("[grok]\nenabled = true\n".utf8).write(to: toml)
        let store = ConfigStore(
            env: DictionaryEnvReader(["XAI_API_KEY": ""]),
            tomlPath: toml
        )
        #expect(store.load().grok.apiKey == nil)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ConfigStoreGrok-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("LocalEngineConfigTests")
struct LocalEngineConfigTests {

    @Test func defaults_includeLmstudioLlamaCpp() {
        let engines = AppConfig.defaults.engines
        #expect(engines.contains(where: { $0.id == .lmstudioLlamaCpp }))
        #expect(engines.first(where: { $0.id == .lmstudioLlamaCpp })?.matchPath
            == "/.lmstudio/extensions/backends/")
    }

    @Test func parse_overlaysBuiltinEnabled() {
        let toml = TomlReader.parse("""
        [engine.lms-llamacpp]
        enabled = false
        """)
        let engines = LocalEngineConfig.parse(from: toml)
        let lms = engines.first { $0.id == .lmstudioLlamaCpp }
        #expect(lms?.enabled == false)
        #expect(lms?.matchPath == "/.lmstudio/extensions/backends/")
    }

    @Test func parse_addsCustomEngine() {
        let toml = TomlReader.parse("""
        [engine.classifier]
        name = "DRM classifier"
        kind = "llamacpp"
        port = 8123
        """)
        let engines = LocalEngineConfig.parse(from: toml)
        let custom = engines.first { $0.id.rawValue == "engine.classifier" }
        #expect(custom?.displayName == "DRM classifier")
        #expect(custom?.port == 8123)
        #expect(custom?.kind == .llamacpp)
        #expect(engines.contains(where: { $0.id == .lmstudioLlamaCpp }))
    }

    @Test func parse_skipsReservedProviderSlug() {
        let toml = TomlReader.parse("""
        [engine.claude]
        port = 9999
        """)
        let engines = LocalEngineConfig.parse(from: toml)
        #expect(engines.contains(where: { $0.id.rawValue == "engine.claude" }) == false)
        #expect(engines.contains(where: { $0.id == .claude }) == false)
    }

    @Test func parse_skipsUnknownKind() {
        let toml = TomlReader.parse("""
        [engine.vllm]
        kind = "openai"
        port = 8000
        """)
        let engines = LocalEngineConfig.parse(from: toml)
        #expect(engines.contains(where: { $0.id.rawValue == "engine.vllm" }) == false)
    }
}

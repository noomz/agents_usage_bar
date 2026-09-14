import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("LocalEngineResolverTests")
struct LocalEngineResolverTests {

    @Test func port_fromSeparateFlag() {
        #expect(LocalEngineResolver.port(fromArguments: ["llama-server", "--port", "8123"]) == 8123)
    }

    @Test func port_fromEqualsFlag() {
        #expect(LocalEngineResolver.port(fromArguments: ["--port=8080"]) == 8080)
    }

    @Test func port_rejectsOutOfRange() {
        #expect(LocalEngineResolver.port(fromArguments: ["--port", "0"]) == nil)
        #expect(LocalEngineResolver.port(fromArguments: ["--port", "70000"]) == nil)
        #expect(LocalEngineResolver.port(fromArguments: ["--host", "127.0.0.1"]) == nil)
    }

    @Test func resolve_usesMatchingProcessPort() {
        let engine = LocalEngineConfig.lmstudioLlamaCpp
        let processes = [
            RunningProcess(
                pid: 1,
                executablePath: "/Users/x/.lmstudio/extensions/backends/llama.cpp-mac/llama-server",
                arguments: ["llama-server", "--port", "8123"]
            )
        ]
        let port = LocalEngineResolver.resolvePort(
            engine: engine,
            processes: processes,
            reservedPorts: [11434, 1234, 8080]
        )
        #expect(port == 8123)
    }

    @Test func resolve_skipsReservedPort() {
        let engine = LocalEngineConfig.lmstudioLlamaCpp
        let processes = [
            RunningProcess(
                pid: 1,
                executablePath: "/Users/x/.lmstudio/extensions/backends/llama-server",
                arguments: ["llama-server", "--port", "8080"]
            )
        ]
        let port = LocalEngineResolver.resolvePort(
            engine: engine,
            processes: processes,
            reservedPorts: [8080]
        )
        #expect(port == nil)
    }

    @Test func resolve_ignoresBrewBinary() {
        let engine = LocalEngineConfig.lmstudioLlamaCpp
        let processes = [
            RunningProcess(
                pid: 9,
                executablePath: "/opt/homebrew/Cellar/llama.cpp/8680/bin/llama-server",
                arguments: ["llama-server", "--port", "8080"]
            )
        ]
        let port = LocalEngineResolver.resolvePort(
            engine: engine,
            processes: processes,
            reservedPorts: []
        )
        #expect(port == nil)
    }

    @Test func resolve_fallsBackToExplicitPort() {
        let engine = LocalEngineConfig(
            id: ProviderID(rawValue: "engine.classifier"),
            displayName: "classifier",
            enabled: true,
            kind: .llamacpp,
            matchPath: nil,
            port: 8123
        )
        let port = LocalEngineResolver.resolvePort(
            engine: engine,
            processes: [],
            reservedPorts: []
        )
        #expect(port == 8123)
    }
}

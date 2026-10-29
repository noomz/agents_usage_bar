import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("PiLocalCatalogTests")
struct PiLocalCatalogTests {

    @Test func llamaCpp_always_local() {
        #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: "llama.cpp"), baseUrl: nil))
        #expect(PiLocalCatalog.isLocal(
            id: PiProviderName(rawValue: "llama.cpp"),
            baseUrl: URL(string: "https://example.com/v1")
        ))
    }

    @Test func cloud_denylist_wins_over_loopback() {
        let loopback = URL(string: "http://127.0.0.1:4000")
        for id in [
            "anthropic", "openai", "openai-codex", "openrouter", "xai",
            "amazon-bedrock", "router", "google", "gemini",
        ] {
            #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: id), baseUrl: loopback) == false)
        }
    }

    @Test func loopback_rfc1918_linkLocal_mdns_dotless_http() {
        #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: "ollama"), baseUrl: URL(string: "http://localhost:11434/v1")))
        #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: "lan"), baseUrl: URL(string: "http://10.1.2.3:8080/v1")))
        #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: "lan"), baseUrl: URL(string: "http://172.16.0.2:8080/v1")))
        #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: "lan"), baseUrl: URL(string: "http://192.168.1.9:8080/v1")))
        #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: "lan"), baseUrl: URL(string: "http://169.254.1.1:8080/v1")))
        #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: "lan"), baseUrl: URL(string: "http://nas.local:8080/v1")))
        #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: "DRM-SWAP"), baseUrl: URL(string: "http://drm:8080/v1")))
        #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: "v6"), baseUrl: URL(string: "http://[::1]:8080/v1")))
        #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: "v6ll"), baseUrl: URL(string: "http://[fe80::1]/v1")))
    }

    @Test func https_public_dns_and_plain_http_public_host_are_remote() {
        #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: "remote"), baseUrl: URL(string: "https://api.example.com/v1")) == false)
        #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: "remote"), baseUrl: URL(string: "http://api.example.com/v1")) == false)
        #expect(PiLocalCatalog.isLocal(id: PiProviderName(rawValue: "missing"), baseUrl: nil) == false)
    }

    @Test func load_unions_local_ids_and_always_includes_llamaCpp() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/models-local.json")
        let catalog = PiLocalCatalog.load(urls: [url])
        #expect(catalog.contains(PiProviderName(rawValue: "DRM-SWAP")))
        #expect(catalog.contains(PiProviderName(rawValue: "ollama")))
        #expect(catalog.contains(PiProviderName(rawValue: "llama.cpp")))
        #expect(catalog.contains(PiProviderName(rawValue: "openrouter")) == false)
        #expect(catalog.contains(PiProviderName(rawValue: "anthropic")) == false)
    }

    @Test func load_missing_file_still_has_llamaCpp() {
        let catalog = PiLocalCatalog.load(urls: [URL(fileURLWithPath: "/tmp/pi-local-missing-models.json")])
        #expect(catalog.contains(PiProviderName(rawValue: "llama.cpp")))
        #expect(catalog.names.count == 1)
    }
}

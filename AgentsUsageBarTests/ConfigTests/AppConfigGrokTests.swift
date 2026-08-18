import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("AppConfigGrokTests")
struct AppConfigGrokTests {

    @Test func defaults_grok_enabled_with_proxy_url() {
        let g = AppConfig.defaults.grok
        #expect(g.enabled == true)
        #expect(g.apiKey == nil)
        #expect(g.apiURL.absoluteString == "https://cli-chat-proxy.grok.com/v1")
    }

    @Test func withEnabled_preserves_url_and_key() {
        let original = GrokConfig(
            enabled: true,
            apiKey: Secret("fake-xai-key"),
            apiURL: URL(string: "https://example.test/v1")!
        )
        let disabled = original.withEnabled(false)
        #expect(disabled.enabled == false)
        #expect(disabled.apiURL == original.apiURL)
        #expect(disabled.apiKey?.description == "<redacted>")
    }
}

import Foundation
import Testing
@testable import AgentsUsageBar

/// Plan 03-07 Task 1 — `ProviderDashboardURL.lookup(_:)` invariants (D-14).
///
/// Source-of-truth tests for the four hard-coded dashboard URLs that the row's
/// trailing "Open dashboard" button consumes. Locking each URL into a test
/// guarantees that any inadvertent edit to the lookup table is caught at the
/// PR boundary.
@MainActor
@Suite("Plan 03-07 Task 1 — ProviderDashboardURL.lookup")
struct ProviderDashboardURLTests {

    // MARK: - Known providers (D-14)

    @Test("openrouter -> https://openrouter.ai/credits")
    func openrouter_mapsToCreditsURL() {
        let url = ProviderDashboardURL.lookup(.openrouter)
        #expect(url?.absoluteString == "https://openrouter.ai/credits")
    }

    @Test("claude -> https://console.anthropic.com/settings/usage")
    func claude_mapsToConsoleUsage() {
        let url = ProviderDashboardURL.lookup(.claude)
        #expect(url?.absoluteString == "https://console.anthropic.com/settings/usage")
    }

    @Test("codex -> https://platform.openai.com/usage")
    func codex_mapsToPlatformUsage() {
        let url = ProviderDashboardURL.lookup(.codex)
        #expect(url?.absoluteString == "https://platform.openai.com/usage")
    }

    @Test("gemini -> https://aistudio.google.com/u/0/usage (must include /u/0/)")
    func gemini_mapsToAIStudioUsage_pinsFirstAccount() {
        let url = ProviderDashboardURL.lookup(.gemini)
        #expect(url?.absoluteString == "https://aistudio.google.com/u/0/usage")
        // D-14 / RESEARCH §"Dashboard URLs": the /u/0/ pin is critical so the
        // dashboard does not land the user on Google's account-picker page.
        #expect(url?.path.contains("/u/0/") == true)
    }

    // MARK: - Unknown providers — return nil

    @Test("ollama -> nil (local LLM, out of Phase 3 scope)")
    func ollama_returnsNil() {
        let url = ProviderDashboardURL.lookup(ProviderID(rawValue: "ollama"))
        #expect(url == nil)
    }

    @Test("lmstudio -> nil (local LLM, out of Phase 3 scope)")
    func lmstudio_returnsNil() {
        let url = ProviderDashboardURL.lookup(ProviderID(rawValue: "lmstudio"))
        #expect(url == nil)
    }

    @Test("llamacpp -> nil (local LLM, out of Phase 3 scope)")
    func llamacpp_returnsNil() {
        let url = ProviderDashboardURL.lookup(ProviderID(rawValue: "llamacpp"))
        #expect(url == nil)
    }

    @Test("unknown future provider rawValue -> nil")
    func unknownProvider_returnsNil() {
        let url = ProviderDashboardURL.lookup(ProviderID(rawValue: "unknown-future-provider"))
        #expect(url == nil)
    }

    // MARK: - Cross-cutting safety invariants

    @Test("every mapped URL uses scheme = https (Hardened Runtime + ATS)")
    func allURLs_areHTTPS() {
        let providers: [ProviderID] = [.openrouter, .claude, .codex, .gemini]
        for p in providers {
            let url = ProviderDashboardURL.lookup(p)
            #expect(url?.scheme == "https", "\(p.rawValue) must be https-only")
        }
    }

    @Test("every mapped URL has a non-empty host")
    func allURLs_haveNonEmptyHost() {
        let providers: [ProviderID] = [.openrouter, .claude, .codex, .gemini]
        for p in providers {
            let url = ProviderDashboardURL.lookup(p)
            #expect((url?.host ?? "").isEmpty == false, "\(p.rawValue) must have a host")
        }
    }
}

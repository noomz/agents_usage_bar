import Testing
@testable import AgentsUsageBar

@Suite("ProviderIDPiLocalTests")
struct ProviderIDPiLocalTests {

    @Test func rawValue_is_piLocal() {
        #expect(ProviderID.piLocal.rawValue == "pi-local")
    }

    @Test func displayHint_is_LocalLlama() {
        #expect(ProviderID.piLocal.displayHint == "Local Llama")
    }

    @Test func allKnown_includes_piLocal_after_grok_before_ollama() {
        let grok = ProviderID.allKnown.firstIndex(of: .grok)
        let piLocal = ProviderID.allKnown.firstIndex(of: .piLocal)
        let ollama = ProviderID.allKnown.firstIndex(of: .ollama)
        #expect(grok != nil && piLocal != nil && ollama != nil)
        #expect(piLocal! == grok! + 1)
        #expect(ollama! == piLocal! + 1)
    }

    @Test func localIDs_unchanged_and_isLocalRuntime_false() {
        #expect(ProviderID.localIDs == Set([.ollama, .lmstudio, .llamacpp, .lmstudioLlamaCpp]))
        #expect(ProviderID.localIDs.contains(.piLocal) == false)
        #expect(ProviderID.piLocal.isLocalRuntime == false)
    }

    @Test func contributesToTodayTotal() {
        #expect(ProviderID.piLocal.contributesToTodayTotal)
        #expect(ProviderID.claude.contributesToTodayTotal)
        #expect(ProviderID.llamacpp.contributesToTodayTotal == false)
    }
}

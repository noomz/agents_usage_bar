import Testing
@testable import AgentsUsageBar

/// Plan 04-01 / T-04-01-04 — locks the three local `ProviderID` constants and the
/// `localIDs` set in place. Future renames of constants or `rawValue` strings will
/// break this suite loudly. Downstream plans 04-04, 04-05, 04-06 key provider actors,
/// cache state, and row rendering on these exact `rawValue`s.
@Suite("ProviderIDLocalConstantsTests")
struct ProviderIDLocalConstantsTests {

    // MARK: - rawValue assertions

    @Test("ProviderID.ollama.rawValue equals \"ollama\"")
    func ollama_rawValueIsOllama() {
        #expect(ProviderID.ollama.rawValue == "ollama")
    }

    @Test("ProviderID.lmstudio.rawValue equals \"lmstudio\"")
    func lmstudio_rawValueIsLmstudio() {
        #expect(ProviderID.lmstudio.rawValue == "lmstudio")
    }

    @Test("ProviderID.llamacpp.rawValue equals \"llamacpp\"")
    func llamacpp_rawValueIsLlamacpp() {
        #expect(ProviderID.llamacpp.rawValue == "llamacpp")
    }

    // MARK: - displayHint assertions (gate against regression in the Phase 1 switch)

    @Test("displayHints render human-readable strings for all three local providers")
    func displayHints_renderHumanReadable() {
        #expect(ProviderID.ollama.displayHint == "Ollama")
        #expect(ProviderID.lmstudio.displayHint == "LM Studio")
        #expect(ProviderID.llamacpp.displayHint == "llama.cpp")
    }

    // MARK: - localIDs set

    @Test("localIDs set equals exactly {ollama, lmstudio, llamacpp}")
    func localIDs_setEqualsThreeMembers() {
        #expect(ProviderID.localIDs == Set([.ollama, .lmstudio, .llamacpp]))
    }

    @Test("localIDs does not contain any hosted provider")
    func localIDs_doesNotContainHostedProviders() {
        #expect(ProviderID.localIDs.contains(.openrouter) == false)
        #expect(ProviderID.localIDs.contains(.claude) == false)
        #expect(ProviderID.localIDs.contains(.codex) == false)
        #expect(ProviderID.localIDs.contains(.gemini) == false)
    }
}

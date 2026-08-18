import Testing
@testable import AgentsUsageBar

@Suite("ProviderIDGrokTests")
struct ProviderIDGrokTests {

    @Test func rawValue_is_grok() {
        #expect(ProviderID.grok.rawValue == "grok")
    }

    @Test func displayHint_is_Grok() {
        #expect(ProviderID.grok.displayHint == "Grok")
    }

    @Test func allKnown_includes_grok_after_gemini() {
        #expect(ProviderID.allKnown.contains(.grok))
        let gemini = ProviderID.allKnown.firstIndex(of: .gemini)
        let grok = ProviderID.allKnown.firstIndex(of: .grok)
        #expect(gemini != nil && grok != nil)
        #expect(grok! == gemini! + 1)
    }

    @Test func grok_is_not_local() {
        #expect(ProviderID.localIDs.contains(.grok) == false)
    }
}

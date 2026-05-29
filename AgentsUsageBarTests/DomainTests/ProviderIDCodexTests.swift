import Testing
@testable import AgentsUsageBar

/// Plan 03-01 Task 1 — locks the `.codex` `ProviderID` constant in place.
///
/// Future renames of either the constant identifier or the `rawValue` string
/// will break this suite loudly. Downstream Plan 03-02 (`CodexJSONLProvider`)
/// and Plan 03-04 (Codex composition into `AggregateStore`) both key cache
/// state, dashboard URLs, and pricing lookups on this exact `rawValue`.
@Suite("ProviderIDCodexTests")
struct ProviderIDCodexTests {

    @Test("ProviderID.codex.rawValue equals \"codex\"")
    func codexRawValueMatchesString() {
        #expect(ProviderID.codex.rawValue == "codex")
    }

    @Test("ProviderID.codex.displayHint returns \"Codex\"")
    func codexDisplayHintMatchesProductLabel() {
        // The switch in `ProviderID.displayHint` already returned "Codex" before
        // this constant existed (Phase 1 declaration); this assertion guards
        // against a future regression where someone alters the displayHint switch
        // without updating the constant, or vice versa.
        #expect(ProviderID.codex.displayHint == "Codex")
    }
}

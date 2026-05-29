import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - AggregateStoreSeedPlaceholderMessageTests
//
// Tests for the extended `AggregateStore.seedPlaceholder(providerID:displayName:placeholderMessage:status:)`
// introduced in Plan 04-06 (T-04-06-03).
//
// Verifies:
// - New `placeholderMessage` parameter is threaded to `ProviderState.placeholderMessage`.
// - Default nil preserves back-compat with Phase 3 callsites (openrouter / claude / codex / gemini).
// - The D-04 verbatim string is round-tripped through the store.

@Suite("AggregateStoreSeedPlaceholderMessageTests")
struct AggregateStoreSeedPlaceholderMessageTests {

    // Helper — minimal AggregateStore with empty registry (no live providers needed).
    @MainActor
    private func makeStore() -> AggregateStore {
        AggregateStore(
            registry: [],
            clock: SystemClock(),
            cache: InMemoryCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoOpNotificationManager()
        )
    }

    @Test @MainActor func seedPlaceholder_acceptsMessage() {
        let store = makeStore()
        store.seedPlaceholder(
            providerID: .llamacpp,
            displayName: "llama.cpp",
            placeholderMessage: "Set [llamacpp] port in config.toml to enable",
            status: .notRunning
        )
        let state = store.providers[.llamacpp]
        #expect(state?.placeholderMessage == "Set [llamacpp] port in config.toml to enable")
        #expect(state?.status == .notRunning)
        #expect(state?.displayName == "llama.cpp")
    }

    @Test @MainActor func seedPlaceholder_messageDefaultsToNil() {
        let store = makeStore()
        store.seedPlaceholder(
            providerID: .ollama,
            displayName: "Ollama"
        )
        let state = store.providers[.ollama]
        #expect(state?.placeholderMessage == nil)
    }

    @Test @MainActor func seedPlaceholder_phase3CallsitesUnchanged() {
        // Exercise the four Phase 3 patterns (three-arg form only):
        // openrouter / claude / codex / gemini placeholder seeds compile unchanged
        // and produce nil placeholderMessage — regression invariant.
        let store = makeStore()

        store.seedPlaceholder(providerID: .openrouter, displayName: "OpenRouter")
        store.seedPlaceholder(providerID: .claude, displayName: "Claude Code")
        store.seedPlaceholder(providerID: .codex, displayName: "Codex")
        store.seedPlaceholder(providerID: .gemini, displayName: "Gemini")

        #expect(store.providers[.openrouter]?.placeholderMessage == nil)
        #expect(store.providers[.claude]?.placeholderMessage == nil)
        #expect(store.providers[.codex]?.placeholderMessage == nil)
        #expect(store.providers[.gemini]?.placeholderMessage == nil)
    }

    @Test @MainActor func seedPlaceholder_statusDefaultsToUnauthenticated() {
        // Default status must remain .unauthenticated for back-compat.
        let store = makeStore()
        store.seedPlaceholder(providerID: .openrouter, displayName: "OpenRouter")
        #expect(store.providers[.openrouter]?.status == .unauthenticated)
    }

    @Test @MainActor func seedPlaceholder_overwritesPriorEntry() {
        let store = makeStore()
        store.seedPlaceholder(
            providerID: .llamacpp,
            displayName: "llama.cpp",
            placeholderMessage: "first message",
            status: .notRunning
        )
        store.seedPlaceholder(
            providerID: .llamacpp,
            displayName: "llama.cpp",
            placeholderMessage: "second message",
            status: .notRunning
        )
        #expect(store.providers[.llamacpp]?.placeholderMessage == "second message")
    }
}

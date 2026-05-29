import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - ProviderStatePlaceholderMessageTests
//
// Tests for the extended `ProviderState.placeholder(providerID:displayName:placeholderMessage:status:)`
// factory introduced in Plan 04-06 (T-04-06-03).
//
// Verifies:
// - New `placeholderMessage` parameter is threaded through to `ProviderState.placeholderMessage`.
// - Default nil preserves back-compat with Phase 1/2/3 call-sites.
// - The D-04 verbatim string "Set [llamacpp] port in config.toml to enable" is carried through.
// - Equatable distinguishes instances differing only in placeholderMessage.

@Suite("ProviderStatePlaceholderMessageTests")
struct ProviderStatePlaceholderMessageTests {

    @Test func placeholderFactory_acceptsMessage() {
        let state = ProviderState.placeholder(
            providerID: .llamacpp,
            displayName: "llama.cpp",
            placeholderMessage: "Set port",
            status: .notRunning
        )
        #expect(state.placeholderMessage == "Set port")
        #expect(state.id == .llamacpp)
        #expect(state.displayName == "llama.cpp")
    }

    @Test func placeholderFactory_defaultsToNil() {
        // Back-compat: calling without placeholderMessage gives nil.
        let state = ProviderState.placeholder(
            providerID: .ollama,
            displayName: "Ollama"
        )
        #expect(state.placeholderMessage == nil)
    }

    @Test func placeholderFactory_carriesNotRunningStatus() {
        // D-04 verbatim string assertion: both status AND placeholderMessage must be preserved.
        let placeholder = ProviderState.placeholder(
            providerID: .llamacpp,
            displayName: "llama.cpp",
            placeholderMessage: "Set [llamacpp] port in config.toml to enable",
            status: .notRunning
        )
        #expect(placeholder.status == .notRunning)
        #expect(placeholder.placeholderMessage == "Set [llamacpp] port in config.toml to enable")
    }

    @Test func equatable_distinguishesMessage() {
        let a = ProviderState.placeholder(
            providerID: .llamacpp,
            displayName: "llama.cpp",
            placeholderMessage: "message-A",
            status: .notRunning
        )
        let b = ProviderState.placeholder(
            providerID: .llamacpp,
            displayName: "llama.cpp",
            placeholderMessage: "message-B",
            status: .notRunning
        )
        #expect(a != b)
    }

    @Test func placeholderFactory_snapshotIsAlwaysNil() {
        // Placeholder rows always have snapshot == nil.
        let state = ProviderState.placeholder(
            providerID: .llamacpp,
            displayName: "llama.cpp",
            placeholderMessage: "some message",
            status: .notRunning
        )
        #expect(state.snapshot == nil)
        #expect(state.lastSuccess == nil)
    }
}

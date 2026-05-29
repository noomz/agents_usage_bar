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

    // MARK: - Plan 04 hotfix — placeholderMessage clears on first successful snapshot

    @Test func applyingSnapshot_clearsStalePlaceholderMessage() {
        // Reviewer scenario: app first launched with [llamacpp] port absent →
        // seedPlaceholder("Set [llamacpp] port in config.toml to enable") writes the cache.
        // User edits config.toml to add port = 8080 → relaunches → first probe succeeds.
        // The stale placeholderMessage MUST clear so LocalRowSecondaryView shows live model
        // data instead of the now-outdated discoverability hint.
        let initial = ProviderState.placeholder(
            providerID: .llamacpp,
            displayName: "llama.cpp",
            placeholderMessage: "Set [llamacpp] port in config.toml to enable",
            status: .notRunning
        )
        let snapshot = UsageSnapshot(
            providerID: .llamacpp,
            asOf: Date(timeIntervalSince1970: 1_700_000_000),
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: ["source": "llamacpp", "modelCount": "1"]
        )
        let next = initial.applying(snapshot: snapshot, at: Date(timeIntervalSince1970: 1_700_000_001))
        #expect(next.placeholderMessage == nil)
        #expect(next.snapshot != nil)
    }

    @Test func applyingError_clearsPlaceholderMessageOncePastFirstSuccess() {
        // After at least one success, transient errors must not resurrect the placeholder hint.
        let withSuccess = ProviderState(
            id: .llamacpp,
            displayName: "llama.cpp",
            placeholderMessage: nil,
            snapshot: UsageSnapshot(
                providerID: .llamacpp,
                asOf: Date(timeIntervalSince1970: 1_700_000_000),
                tokensToday: nil,
                costTodayUSD: nil,
                balanceUSD: nil,
                quota: nil,
                raw: [:]
            ),
            status: .ok(lastSuccess: Date(timeIntervalSince1970: 1_700_000_000)),
            lastSuccess: Date(timeIntervalSince1970: 1_700_000_000)
        )
        struct StubError: Error {}
        let next = withSuccess.applyingError(StubError(), at: Date(timeIntervalSince1970: 1_700_000_500))
        #expect(next.placeholderMessage == nil)
    }

    @Test func applyingError_preservesPlaceholderBeforeFirstSuccess() {
        // Pure placeholder (no prior success) — transient probe error MUST keep the hint.
        let pure = ProviderState.placeholder(
            providerID: .llamacpp,
            displayName: "llama.cpp",
            placeholderMessage: "Set [llamacpp] port in config.toml to enable",
            status: .notRunning
        )
        struct StubError: Error {}
        let next = pure.applyingError(StubError(), at: Date(timeIntervalSince1970: 1_700_000_500))
        #expect(next.placeholderMessage == "Set [llamacpp] port in config.toml to enable")
    }

    // MARK: - Plan 04 hotfix H-02 — sentinel raw["providerStatus"] = "notRunning" overrides .ok

    @Test func applyingSnapshot_honorsNotRunningSentinel() {
        // Reviewer scenario Test 4: stop llama-server with model previously loaded.
        // Actor returns mutedNotRunningSnapshot (never throws — GEMINI-04 isolation).
        // AggregateStore.apply(.success(snap)) MUST yield status=.notRunning + preserve
        // lastSuccess (not a real probe success). Without this branch, UI shows
        // state B "Idle — 0 models loaded" indistinguishable from a running runtime.
        let priorSuccess = Date(timeIntervalSince1970: 1_700_000_000)
        let withSuccess = ProviderState(
            id: .ollama,
            displayName: "Ollama",
            placeholderMessage: nil,
            snapshot: UsageSnapshot(
                providerID: .ollama,
                asOf: priorSuccess,
                tokensToday: nil,
                costTodayUSD: nil,
                balanceUSD: nil,
                quota: nil,
                raw: ["source": "ollama", "modelCount": "1", "modelName": "llama3:8b"]
            ),
            status: .ok(lastSuccess: priorSuccess),
            lastSuccess: priorSuccess
        )
        let mutedSnap = UsageSnapshot(
            providerID: .ollama,
            asOf: Date(timeIntervalSince1970: 1_700_000_500),
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: ["modelCount": "0", "source": "ollama", "providerStatus": "notRunning"]
        )
        let next = withSuccess.applying(snapshot: mutedSnap, at: Date(timeIntervalSince1970: 1_700_000_500))
        #expect(next.status == .notRunning)
        #expect(next.lastSuccess == priorSuccess)   // NOT advanced — outage isn't a success
        #expect(next.snapshot != nil)               // muted snapshot stored for raw inspection
    }

    @Test func applyingSnapshot_okPathUnchangedWhenSentinelAbsent() {
        // Regression guard: a normal successful probe (no sentinel) still yields .ok and
        // advances lastSuccess. The H-02 branch must not affect the happy path.
        let initial = ProviderState.placeholder(
            providerID: .ollama,
            displayName: "Ollama",
            status: .notRunning
        )
        let liveSnap = UsageSnapshot(
            providerID: .ollama,
            asOf: Date(timeIntervalSince1970: 1_700_000_500),
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: ["source": "ollama", "modelCount": "1", "modelName": "llama3:8b"]
        )
        let next = initial.applying(snapshot: liveSnap, at: Date(timeIntervalSince1970: 1_700_000_500))
        if case .ok = next.status { /* ok */ } else { Issue.record("expected .ok, got \(next.status)") }
        #expect(next.lastSuccess == Date(timeIntervalSince1970: 1_700_000_500))
    }
}

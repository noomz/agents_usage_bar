import Foundation
import Testing
@testable import AgentsUsageBar

/// Plan 04-07 T-03 — `LocalRowSecondaryView.secondaryText` value-type tests.
///
/// All tests operate on the `internal var secondaryText: String` accessor —
/// no SwiftUI runtime instantiation required. Covers all six D-02/D-03 row
/// states (A, B, B', C, D, E) + the D-04 placeholderMessage path, plus LOCAL-06
/// and `ProviderID.localIDs` regression assertions.
// `@MainActor` because every test instantiates `LocalRowSecondaryView` (a
// SwiftUI `View`, hence `@MainActor` under Swift 6) and reads its
// `secondaryText`. Unlike `QuotaBar`'s pure static `color(forFraction:)` seam,
// there is no nonisolated path here — the View's `init(state:)` is itself
// MainActor-isolated — so the test suite must run on the main actor.
@MainActor
@Suite("Plan 04-07 — LocalRowSecondaryView secondaryText states")
struct LocalRowSecondaryViewTests {

    // MARK: - Helper

    private func makeState(
        id: ProviderID = .ollama,
        status: ProviderStatus = .ok(lastSuccess: .now),
        placeholderMessage: String? = nil,
        raw: [String: String] = [:]
    ) -> ProviderState {
        let snapshot = UsageSnapshot(
            providerID: id,
            asOf: .now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: raw
        )
        return ProviderState(
            id: id,
            displayName: id.displayHint,
            placeholderMessage: placeholderMessage,
            snapshot: snapshot,
            status: status,
            lastSuccess: .now
        )
    }

    // MARK: - State A: Not running

    @Test("State A — .notRunning status yields 'Not running'")
    func stateA_notRunning_yieldsNotRunningString() {
        let state = makeState(status: .notRunning, raw: ["modelCount": "0"])
        #expect(LocalRowSecondaryView(state: state).secondaryText == "Not running")
    }

    // MARK: - State B: Idle — 0 models loaded

    @Test("State B — idle, zero models loaded, ok status")
    func stateB_idleZeroModelsLoaded_okStatusEmptyModelCount() {
        // installedCount absent (positive default) → "Idle — 0 models loaded"
        let state = makeState(status: .ok(lastSuccess: .now), raw: ["modelCount": "0"])
        #expect(LocalRowSecondaryView(state: state).secondaryText == "Idle — 0 models loaded")
    }

    @Test("State B — idle, installedCount positive, ok status → 'Idle — 0 models loaded'")
    func stateB_idleWithInstalledModels_yieldsIdleLoaded() {
        let state = makeState(status: .ok(lastSuccess: .now), raw: ["modelCount": "0", "installedCount": "3"])
        #expect(LocalRowSecondaryView(state: state).secondaryText == "Idle — 0 models loaded")
    }

    // MARK: - State B': Idle — no models installed

    @Test("State B' — idle, no models installed (installedCount=0)")
    func stateBPrime_idleNoModelsInstalled() {
        let state = makeState(status: .ok(lastSuccess: .now), raw: ["modelCount": "0", "installedCount": "0"])
        #expect(LocalRowSecondaryView(state: state).secondaryText == "Idle — no models installed")
    }

    // MARK: - State C: Single model

    @Test("State C — single model by name, no VRAM suffix when vramBytes absent")
    func stateC_singleModelByName() {
        let state = makeState(raw: ["modelCount": "1", "modelName": "llama3:8b"])
        #expect(LocalRowSecondaryView(state: state).secondaryText == "llama3:8b")
    }

    @Test("State C — single model with VRAM suffix (5137025024 bytes → 4.8 GB)")
    func stateC_singleModelWithVRAM() {
        let state = makeState(raw: [
            "modelCount": "1",
            "modelName": "llama3:8b",
            "vramBytes": "5137025024"
        ])
        #expect(LocalRowSecondaryView(state: state).secondaryText == "llama3:8b · 4.8 GB VRAM")
    }

    @Test("State C — zero vramBytes suppresses VRAM suffix (CPU-only case, OQ-4)")
    func stateC_singleModelZeroVRAM_suppressedSuffix() {
        let state = makeState(raw: [
            "modelCount": "1",
            "modelName": "llama3:8b",
            "vramBytes": "0"
        ])
        let text = LocalRowSecondaryView(state: state).secondaryText
        #expect(text == "llama3:8b", "Zero vramBytes must NOT produce a VRAM suffix")
        #expect(!text.contains("GB VRAM"))
    }

    // MARK: - State D: Multiple models

    @Test("State D — three models loaded → '<name> · +2 more'")
    func stateD_threeModelsLoaded() {
        let state = makeState(raw: [
            "modelCount": "3",
            "modelName": "llama3:8b",
            "allModels": "llama3:8b|mistral:latest|codellama:13b"
        ])
        #expect(LocalRowSecondaryView(state: state).secondaryText == "llama3:8b · +2 more")
    }

    @Test("State D — two models loaded → '<name> · +1 more'")
    func stateD_twoModelsLoaded() {
        let state = makeState(raw: [
            "modelCount": "2",
            "modelName": "mistral:latest"
        ])
        #expect(LocalRowSecondaryView(state: state).secondaryText == "mistral:latest · +1 more")
    }

    // MARK: - State E: Loading model

    @Test("State E — loadingModel=true yields 'Running — loading model…'")
    func stateE_loadingModel_yieldsLoadingString() {
        let state = makeState(status: .ok(lastSuccess: .now), raw: ["loadingModel": "true"])
        #expect(LocalRowSecondaryView(state: state).secondaryText == "Running — loading model…")
    }

    @Test("State E — loadingModel takes precedence over modelCount=3")
    func stateE_takesPrecedenceOverModelCount() {
        let state = makeState(raw: [
            "loadingModel": "true",
            "modelCount": "3",
            "modelName": "llama3:8b"
        ])
        #expect(LocalRowSecondaryView(state: state).secondaryText == "Running — loading model…",
                "loadingModel branch must be checked FIRST — before model-count logic")
    }

    // MARK: - D-04 placeholder message

    @Test("placeholderMessage takes precedence over all row states")
    func placeholderMessage_takesPrecedenceOverAllStates() {
        let state = makeState(
            status: .notRunning,
            placeholderMessage: "Set [llamacpp] port in config.toml to enable",
            raw: ["modelCount": "0"]
        )
        #expect(LocalRowSecondaryView(state: state).secondaryText
                == "Set [llamacpp] port in config.toml to enable")
    }

    @Test("Empty placeholderMessage does not shadow — falls through to model-count logic")
    func emptyPlaceholderMessage_doesNotShadow() {
        let state = makeState(
            status: .notRunning,
            placeholderMessage: "",
            raw: ["modelCount": "0"]
        )
        // Falls through to State A
        #expect(LocalRowSecondaryView(state: state).secondaryText == "Not running")
    }

    // MARK: - Fallback

    @Test("Unknown state with empty raw and unauthenticated status → '—' defensive fallback")
    func unknownState_fallbackToDashEm() {
        // .unauthenticated is not .notRunning, raw has no modelCount → count=0
        // installedCount defaults to -1 → "Idle — 0 models loaded" NOT "—"
        // To hit the fallback we need count>0 but no modelName.
        // count=2 with no modelName hits the `if count > 1, let name` guard and
        // falls through to the "—" default.
        let state = makeState(
            status: .ok(lastSuccess: .now),
            raw: ["modelCount": "2"]   // count=2 but modelName absent
        )
        #expect(LocalRowSecondaryView(state: state).secondaryText == "—",
                "count>1 with no modelName must produce the '—' safe default")
    }

    // MARK: - ProviderID.localIDs regression

    @Test("ProviderID.localIDs contains exactly ollama, lmstudio, llamacpp (Plan 04-01 contract)")
    func localIDsCarrier_containsOllamaLMStudioLlamacpp() {
        #expect(ProviderID.localIDs == Set([.ollama, .lmstudio, .llamacpp]),
                "Plan 04-01 localIDs Set must contain exactly the three local runtime IDs")
    }

    // MARK: - LOCAL-06 enforcement

    @Test("LOCAL-06 — secondaryText never emits USD / $ / tokens / bal even when snapshot has cost fields")
    func noLocal06Leak_secondaryTextNeverIncludesUSD() {
        // Build a snapshot with ALL financial fields populated.
        let snapshot = UsageSnapshot(
            providerID: .ollama,
            asOf: .now,
            tokensToday: 999,
            costTodayUSD: Decimal(99.99),
            balanceUSD: Decimal(50.00),
            quota: nil,
            raw: ["modelCount": "1", "modelName": "llama3:8b"]
        )
        let state = ProviderState(
            id: .ollama,
            displayName: "Ollama",
            placeholderMessage: nil,
            snapshot: snapshot,
            status: .ok(lastSuccess: .now),
            lastSuccess: .now
        )
        let text = LocalRowSecondaryView(state: state).secondaryText
        #expect(!text.contains("USD"),    "LOCAL-06: secondaryText must never contain 'USD'")
        #expect(!text.contains("$"),      "LOCAL-06: secondaryText must never contain '$'")
        #expect(!text.contains("tokens"), "LOCAL-06: secondaryText must never contain 'tokens'")
        #expect(!text.contains("bal"),    "LOCAL-06: secondaryText must never contain 'bal'")
    }
}

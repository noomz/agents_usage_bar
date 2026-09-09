import SwiftUI

/// Plan 04-07 — secondary-line rendering for local (Ollama / LM Studio / llama.cpp) rows.
///
/// Replaces the tokens · USD · balance HStack from ProviderRowView (Phase 1 lines 72-91)
/// for any row whose ProviderID is in ProviderID.localIDs (per Plan 04-01 STATE).
///
/// LOCAL-06 anti-feature enforcement: this view NEVER renders token / cost / balance
/// figures. The verification gate is the test suite LocalRowSecondaryViewTests + a
/// ProviderRowView source-grep asserting locals NEVER reach tokenText/usdText/balanceText.
public struct LocalRowSecondaryView: View {
    public let state: ProviderState
    public init(state: ProviderState) { self.state = state }

    public var body: some View {
        Text(secondaryText)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    /// Pure value-type helper — exposed `internal` for direct unit-testing.
    /// Delegates to `ProviderState.localSecondaryCaption` (shared with `aub`).
    internal var secondaryText: String {
        state.localSecondaryCaption
    }
}

// MARK: - Previews

@MainActor
private func previewStore() -> AggregateStore {
    AggregateStore(
        registry: [],
        clock: SystemClock(),
        cache: NoopCacheStore(),
        thresholds: ThresholdEngine(),
        notifications: NoopNotificationManager()
    )
}

#Preview("LocalRowSecondaryView — State A: Not running") {
    let state = ProviderState(
        id: .ollama,
        displayName: "Ollama",
        snapshot: nil,
        status: .notRunning,
        lastSuccess: nil
    )
    return LocalRowSecondaryView(state: state)
        .frame(width: 300)
        .padding()
}

#Preview("LocalRowSecondaryView — State B: Idle 0 models loaded") {
    let snapshot = UsageSnapshot(
        providerID: .ollama,
        asOf: .now,
        tokensToday: nil,
        costTodayUSD: nil,
        balanceUSD: nil,
        quota: nil,
        raw: ["modelCount": "0"]
    )
    let state = ProviderState(
        id: .ollama,
        displayName: "Ollama",
        snapshot: snapshot,
        status: .ok(lastSuccess: .now),
        lastSuccess: .now
    )
    return LocalRowSecondaryView(state: state)
        .frame(width: 300)
        .padding()
}

#Preview("LocalRowSecondaryView — State B': Idle no models installed") {
    let snapshot = UsageSnapshot(
        providerID: .ollama,
        asOf: .now,
        tokensToday: nil,
        costTodayUSD: nil,
        balanceUSD: nil,
        quota: nil,
        raw: ["modelCount": "0", "installedCount": "0"]
    )
    let state = ProviderState(
        id: .ollama,
        displayName: "Ollama",
        snapshot: snapshot,
        status: .ok(lastSuccess: .now),
        lastSuccess: .now
    )
    return LocalRowSecondaryView(state: state)
        .frame(width: 300)
        .padding()
}

#Preview("LocalRowSecondaryView — State C: Single model with VRAM") {
    let snapshot = UsageSnapshot(
        providerID: .ollama,
        asOf: .now,
        tokensToday: nil,
        costTodayUSD: nil,
        balanceUSD: nil,
        quota: nil,
        raw: [
            "modelName": "llama3:8b",
            "modelCount": "1",
            "vramBytes": "5137025024"
        ]
    )
    let state = ProviderState(
        id: .ollama,
        displayName: "Ollama",
        snapshot: snapshot,
        status: .ok(lastSuccess: .now),
        lastSuccess: .now
    )
    return LocalRowSecondaryView(state: state)
        .frame(width: 300)
        .padding()
}

#Preview("LocalRowSecondaryView — State D: Multiple models") {
    let snapshot = UsageSnapshot(
        providerID: .ollama,
        asOf: .now,
        tokensToday: nil,
        costTodayUSD: nil,
        balanceUSD: nil,
        quota: nil,
        raw: [
            "modelName": "llama3:8b",
            "modelCount": "3",
            "allModels": "llama3:8b|mistral:latest|codellama:13b"
        ]
    )
    let state = ProviderState(
        id: .ollama,
        displayName: "Ollama",
        snapshot: snapshot,
        status: .ok(lastSuccess: .now),
        lastSuccess: .now
    )
    return LocalRowSecondaryView(state: state)
        .frame(width: 300)
        .padding()
}

#Preview("LocalRowSecondaryView — State E: Loading model") {
    let snapshot = UsageSnapshot(
        providerID: .llamacpp,
        asOf: .now,
        tokensToday: nil,
        costTodayUSD: nil,
        balanceUSD: nil,
        quota: nil,
        raw: ["loadingModel": "true", "modelCount": "0"]
    )
    let state = ProviderState(
        id: .llamacpp,
        displayName: "llama.cpp",
        snapshot: snapshot,
        status: .ok(lastSuccess: .now),
        lastSuccess: .now
    )
    return LocalRowSecondaryView(state: state)
        .frame(width: 300)
        .padding()
}

#Preview("LocalRowSecondaryView — D-04 placeholder message") {
    let state = ProviderState(
        id: .llamacpp,
        displayName: "llama.cpp",
        placeholderMessage: "Set [llamacpp] port in config.toml to enable",
        snapshot: nil,
        status: .notRunning,
        lastSuccess: nil
    )
    return LocalRowSecondaryView(state: state)
        .frame(width: 300)
        .padding()
}

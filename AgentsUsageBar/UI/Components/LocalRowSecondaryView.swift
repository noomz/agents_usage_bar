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
    internal var secondaryText: String {
        // D-04 placeholder takes precedence — Plan 04-08 seeds this with the
        // "Set [llamacpp] port in config.toml to enable" subtitle.
        if let msg = state.placeholderMessage, !msg.isEmpty {
            return msg
        }

        // State E (RESEARCH §5.1 row E) — llama.cpp transient warmup.
        if state.snapshot?.raw["loadingModel"] == "true" {
            return "Running — loading model…"
        }

        // State A — lastStatus == .notRunning (RESEARCH §5.1 row A).
        if case .notRunning = state.status {
            return "Not running"
        }

        let raw = state.snapshot?.raw ?? [:]
        let count = Int(raw["modelCount"] ?? "") ?? 0
        let installedCount = Int(raw["installedCount"] ?? "") ?? -1
        let name = raw["modelName"]
        let vramBytes = Int64(raw["vramBytes"] ?? "") ?? 0
        let vramSuffix: String = {
            guard vramBytes > 0 else { return "" }
            // RESEARCH §5.1 — format "X.X GB VRAM" via Double / GiB.
            let gb = Double(vramBytes) / 1_073_741_824.0
            return String(format: " · %.1f GB VRAM", gb)
        }()

        if count == 0 {
            if installedCount == 0 {
                return "Idle — no models installed"  // State B' (degenerate)
            }
            return "Idle — 0 models loaded"  // State B
        }

        if count == 1, let name {
            return "\(name)\(vramSuffix)"  // State C
        }

        if count > 1, let name {
            return "\(name) · +\(count - 1) more"  // State D
        }

        // Fallback — should never reach unless rendering a snapshot from a
        // future provider with an unknown raw shape; print "—" as a safe default.
        return "—"
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

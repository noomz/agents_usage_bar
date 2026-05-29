import SwiftUI
import AppKit

// MARK: - SettingsProvidersTab

/// Settings → Providers tab.
///
/// Shows all 7 providers with:
/// - Enable/disable toggle (writes to `UserPreferencesStore` via `.preferences` env key — D-04)
/// - Detection badge (Detected / Not running / Not configured / Not detected)
/// - Re-check button per row (re-runs `DetectionProbe.probeAll` — D-16)
/// - Expandable "How to enable" `DisclosureGroup` panel for undetected rows (D-14)
/// - Copy-to-clipboard buttons for env-var and TOML snippets (NSPasteboard.general — D-15)
///
/// Auto re-checks all providers on tab appear (D-16).
///
/// D-04 NOTE: `onToggle` calls ONLY `preferences.setProviderEnabled(_:enabled:)`.
/// The AggregateStore wiring (live-disconnect on toggle) lives in
/// `AppDependencies.observePreferences` (Plan 05-03 Task 3) — NOT here.
struct SettingsProvidersTab: View {

    @Environment(\.preferences) private var preferences

    @State private var detectionResults: [ProviderID: DetectionResult] = [:]
    @State private var onboardingCopy: OnboardingCopy?
    @State private var expandedRows: Set<ProviderID> = []
    @State private var isChecking: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ProviderID.allKnown, id: \.rawValue) { providerID in
                    ProviderSettingsRow(
                        providerID: providerID,
                        isEnabled: preferences.providerEnabled[providerID] ?? true,
                        detectionResult: detectionResults[providerID],
                        onboardingInfo: onboardingCopy?.providers.first {
                            $0.providerID == providerID.rawValue
                        },
                        isExpanded: expandedRows.contains(providerID),
                        isChecking: isChecking,
                        onToggle: { enabled in
                            // D-04: only mutate UserPreferencesStore — AggregateStore
                            // wiring is handled by AppDependencies.observePreferences
                            preferences.setProviderEnabled(providerID, enabled: enabled)
                        },
                        onRecheck: {
                            Task { await recheckProvider(providerID) }
                        },
                        onToggleExpand: {
                            if expandedRows.contains(providerID) {
                                expandedRows.remove(providerID)
                            } else {
                                expandedRows.insert(providerID)
                            }
                        }
                    )
                    Divider()
                }
            }
            .padding(.vertical, 8)
        }
        .frame(minWidth: 520, minHeight: 300)
        .onAppear {
            loadOnboardingCopy()
            // D-16: auto re-check all providers when tab becomes visible
            Task { await runAllProbes() }
        }
    }

    // MARK: - Private

    private func loadOnboardingCopy() {
        guard onboardingCopy == nil else { return }
        onboardingCopy = try? OnboardingCopy.loadBundled()
    }

    /// Runs all 7 detection probes concurrently (D-12 / D-16).
    /// Creates a fresh 2s URLSessionHTTPClient for detection — acceptable because
    /// detection runs once-per-tab-open, not in the polling loop.
    private func runAllProbes() async {
        isChecking = true
        let config = ConfigStore(env: ProcessInfoEnvReader()).load()
        let http = URLSessionHTTPClient(timeoutSeconds: 2)
        detectionResults = await DetectionProbe.probeAll(config: config, localhostHTTP: http)
        isChecking = false
    }

    /// Re-checks a single provider by running all probes and extracting the result.
    /// Wall-clock is still ≤2s (all 7 probes run in parallel; only the one result is used).
    private func recheckProvider(_ id: ProviderID) async {
        let config = ConfigStore(env: ProcessInfoEnvReader()).load()
        let http = URLSessionHTTPClient(timeoutSeconds: 2)
        let results = await DetectionProbe.probeAll(config: config, localhostHTTP: http)
        detectionResults[id] = results[id]
    }
}

// MARK: - ProviderSettingsRow

private struct ProviderSettingsRow: View {
    let providerID: ProviderID
    let isEnabled: Bool
    let detectionResult: DetectionResult?
    let onboardingInfo: ProviderOnboardingInfo?
    let isExpanded: Bool
    let isChecking: Bool
    let onToggle: (Bool) -> Void
    let onRecheck: () -> Void
    let onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row: provider name + detection badge + re-check + toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(providerID.displayHint)
                        .fontWeight(.medium)
                    detectionBadge
                }

                Spacer()

                // Re-check button (always visible, disabled while checking — D-16)
                Button {
                    onRecheck()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isChecking)
                .accessibilityLabel("Re-check \(providerID.displayHint)")

                // Enable/disable toggle (writes to UserPreferencesStore only — D-04)
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Enable \(providerID.displayHint)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Expandable "How to enable" panel (D-14) — shown only when not detected/configured
            if shouldShowHelpPanel {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { isExpanded },
                        set: { _ in onToggleExpand() }
                    ),
                    content: {
                        if let info = onboardingInfo {
                            OnboardingHelpPanel(info: info)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                        }
                    },
                    label: {
                        Text("How to enable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                    }
                )
            }
        }
    }

    /// Show the help panel for not-detected, not-configured, and unknown (nil) states.
    private var shouldShowHelpPanel: Bool {
        guard onboardingInfo != nil else { return false }
        switch detectionResult {
        case .detected, .notRunning:
            return false
        case .notDetected, .notConfigured, .none:
            return true
        }
    }

    @ViewBuilder
    private var detectionBadge: some View {
        if isChecking {
            Text("Checking…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch detectionResult {
            case .detected:
                Label("Detected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .notRunning:
                Label("Not running", systemImage: "circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .notConfigured:
                Label("Not configured", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .notDetected:
                Label("Not detected", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        }
    }
}

// MARK: - OnboardingHelpPanel

/// Expandable help panel content: description, env snippet + copy button,
/// TOML snippet + copy button, optional docs link.
private struct OnboardingHelpPanel: View {
    let info: ProviderOnboardingInfo
    @State private var copiedEnv = false
    @State private var copiedToml = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(info.detectionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Environment variable snippet + Copy button
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Environment variable")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button(copiedEnv ? "Copied!" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(info.envSnippet, forType: .string)
                        copiedEnv = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copiedEnv = false
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                }
                Text(info.envSnippet)
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .cornerRadius(4)
                Text(info.envNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // config.toml snippet + Copy button
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("config.toml")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button(copiedToml ? "Copied!" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(info.tomlSnippet, forType: .string)
                        copiedToml = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copiedToml = false
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                }
                Text(info.tomlSnippet)
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .cornerRadius(4)
                Text(info.tomlNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Optional documentation link
            if let docsURLString = info.docsURL, let url = URL(string: docsURLString) {
                Link("Open docs ↗", destination: url)
                    .font(.caption)
            }
        }
    }
}

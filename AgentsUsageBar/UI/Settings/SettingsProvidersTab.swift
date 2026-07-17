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
                    // Claude-only: usage-source picker + hook install controls (design §8).
                    if providerID == .claude {
                        ClaudeSourceSection()
                            .environment(\.preferences, preferences)
                    }
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

// MARK: - ClaudeSourceSection

/// Claude-only sub-panel (design §8, per-account per DESIGN-hook-multi-account §7)
/// rendered beneath the Claude provider row.
///
/// - Segmented `Picker` selecting `ClaudeUsageSource` (session reads vs hook), written
///   straight to `UserPreferencesStore.setClaudeSource(_:)` — the switchable facade reads
///   the same UserDefaults key on its next poll.
/// - Per-target install list: one row per `ClaudeHookInstaller.HookTarget` (the default
///   `~/.claude` account plus every `~/.ccs/instances/<slug>`), each with its own status
///   badge + Install / Uninstall button. Installer filesystem work runs on a detached
///   background Task; statuses are refreshed afterward (and on appear).
/// - A caption explaining what hook mode does, its Pro/Max requirement, and how ccs
///   instances are detected.
private struct ClaudeSourceSection: View {
    @Environment(\.preferences) private var preferences

    @State private var targets: [ClaudeHookInstaller.HookTarget] = []
    @State private var statuses: [String: ClaudeHookInstaller.Status] = [:]
    @State private var workingSlugs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Usage-source picker (D-04-style: mutate UserPreferencesStore only).
            Picker("Usage source", selection: Binding(
                get: { preferences.claudeSource },
                set: { preferences.setClaudeSource($0) }
            )) {
                Text("Session reads").tag(ClaudeUsageSource.sessionReads)
                Text("Hook (real usage)").tag(ClaudeUsageSource.hook)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Claude usage source")

            // Per-target install rows, shown only when the user opted into hook mode.
            if preferences.claudeSource == .hook {
                ForEach(targets) { target in
                    HStack(spacing: 8) {
                        Text(target.displayName)
                            .font(.caption)
                        statusLabel(for: target)
                        Spacer()
                        actionButton(for: target)
                    }
                }
            }

            Text("Hook mode reads real usage and rate limits that Claude Code pushes to its status line (Pro/Max required for rate-limit data). ccs instances are detected from ~/.ccs/instances — install the hook into each account you want tracked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .onAppear { refreshTargets() }
    }

    @ViewBuilder
    private func statusLabel(for target: ClaudeHookInstaller.HookTarget) -> some View {
        switch statuses[target.slug] ?? .notInstalled {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .notInstalled:
            Label("Not installed", systemImage: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .foreignStatusline:
            Label("Statusline will be chained", systemImage: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func actionButton(for target: ClaudeHookInstaller.HookTarget) -> some View {
        let isWorking = workingSlugs.contains(target.slug)
        if (statuses[target.slug] ?? .notInstalled) == .installed {
            Button("Uninstall") { perform(target: target, install: false) }
                .font(.caption)
                .disabled(isWorking)
        } else {
            Button("Install") { perform(target: target, install: true) }
                .font(.caption)
                .disabled(isWorking)
        }
    }

    // MARK: - Actions

    /// Discovers targets and reads every installer status off the main thread.
    private func refreshTargets() {
        Task {
            let (found, states) = await Task.detached(
                priority: .userInitiated
            ) { () -> ([ClaudeHookInstaller.HookTarget], [String: ClaudeHookInstaller.Status]) in
                let found = ClaudeHookInstaller.discoverTargets()
                var states: [String: ClaudeHookInstaller.Status] = [:]
                for target in found {
                    states[target.slug] = ClaudeHookInstaller(target: target).status()
                }
                return (found, states)
            }.value
            targets = found
            statuses = states
        }
    }

    /// Installs or uninstalls one target, then refreshes that target's status.
    private func perform(target: ClaudeHookInstaller.HookTarget, install: Bool) {
        workingSlugs.insert(target.slug)
        Task {
            let status = await Task.detached(priority: .userInitiated) { () -> ClaudeHookInstaller.Status in
                let installer = ClaudeHookInstaller(target: target)
                if install {
                    try? installer.install()
                } else {
                    try? installer.uninstall()
                }
                return installer.status()
            }.value
            statuses[target.slug] = status
            workingSlugs.remove(target.slug)
        }
    }
}

import SwiftUI
import ServiceManagement
import os

/// General Settings tab — refresh interval, warning threshold, theme, open-at-login.
///
/// All four controls are bound to `UserPreferencesStore` via explicit setters (D-07).
/// Hot-reload happens via `AppDependencies.observePreferences` in AppDependencies.swift (D-04):
/// - Refresh interval → `PollScheduler.updateInterval(_:)` (no action needed here)
/// - Threshold        → `AggregateStore.updateWarningFraction(_:)` (no action needed here)
/// - Theme            → `.preferredColorScheme` at root scene level (D-04)
/// - Open at login    → `SMAppService.mainApp` called directly from `toggleOpenAtLogin(_:)` (D-08)
struct SettingsGeneralTab: View {

    @Environment(\.preferences) private var preferences
    @Environment(AggregateStore.self) private var store

    /// Local mirror of SMAppService status — read on appear + after toggle attempt.
    @State private var loginItemStatus: SMAppService.Status = .notRegistered

    private let logger = AppLogger.logger(category: "settings.general")

    var body: some View {
        Form {
            // MARK: Refresh Interval (D-07, POLL-02)
            Section("Refresh Interval") {
                Picker("Poll every", selection: Binding(
                    get: { preferences.refreshInterval },
                    set: { preferences.setRefreshInterval($0) }
                )) {
                    Text("Manual").tag(RefreshInterval.manual)
                    Text("1 min").tag(RefreshInterval.m1)
                    Text("2 min").tag(RefreshInterval.m2)
                    Text("5 min").tag(RefreshInterval.m5)
                    Text("15 min").tag(RefreshInterval.m15)
                    Text("30 min").tag(RefreshInterval.m30)
                }
                .pickerStyle(.menu)
            }

            // MARK: Warning Threshold (D-07, Discretion)
            Section("Notifications") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Warn when usage reaches")
                        Spacer()
                        Text("\(Int(preferences.threshold * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { preferences.threshold },
                            set: { preferences.setThreshold($0) }
                        ),
                        in: 0.5...0.95,
                        step: 0.05
                    )
                    .accessibilityLabel("Warning threshold")
                    .accessibilityValue("\(Int(preferences.threshold * 100)) percent")
                }
            }

            // MARK: Theme (D-07, Discretion)
            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { preferences.theme },
                    set: { preferences.setTheme($0) }
                )) {
                    Text("Light").tag(AppTheme.light)
                    Text("Dark").tag(AppTheme.dark)
                    Text("Auto").tag(AppTheme.auto)
                }
                .pickerStyle(.segmented)
            }

            // MARK: Open at Login (D-07, D-08, CFG-05)
            Section("System") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Open at login", isOn: Binding(
                        get: { preferences.openAtLogin },
                        set: { newValue in
                            Task { @MainActor in
                                await toggleOpenAtLogin(newValue)
                            }
                        }
                    ))

                    // Show status subtitle for .requiresApproval and .notFound
                    switch loginItemStatus {
                    case .requiresApproval:
                        HStack(spacing: 4) {
                            Text("Approve in System Settings")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open Login Items \u{2197}") {
                                openLoginItemsSettings()
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                        }
                    case .notFound:
                        Text("Configuration error — see app bundle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    case .enabled:
                        Text("Opens at login")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    default:
                        EmptyView()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    // MARK: - Actions

    /// Calls SMAppService.register() / .unregister() and persists the result only on success.
    ///
    /// On failure: silently reverts UI toggle (macOS norm per CONTEXT Discretion — no toast,
    /// no alert, just an os.Logger warning). The @Observable store still holds the old value
    /// so the Toggle binding snaps back automatically.
    @MainActor
    private func toggleOpenAtLogin(_ newValue: Bool) async {
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
            // Only persist the new value when the system call succeeds
            preferences.setOpenAtLogin(newValue)
        } catch {
            // Silent revert — do NOT crash, do NOT toast (macOS norm per CONTEXT Discretion).
            logger.warning("SMAppService toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        // Re-read authoritative status (may move to .requiresApproval on first call — D-08)
        loginItemStatus = SMAppService.mainApp.status
    }

    /// D-08: deep-link to System Settings → Login Items pane.
    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

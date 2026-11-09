import Sparkle
import SwiftUI

/// Settings → About tab.
///
/// Shows app version + build, GitHub repo link, license link, and a manual
/// Sparkle "Check for Updates…" button.
struct SettingsAboutTab: View {
    @State private var updateCheck: UpdateCheck

    init(updater: SPUUpdater) {
        _updateCheck = State(initialValue: UpdateCheck(updater: updater))
    }

    // Read version + build from bundle at render time — no state needed.
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 20) {
            // App icon + name
            VStack(spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)

                Text("Agents Usage Bar")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Version \(version) (\(build))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Divider()

            // Links
            VStack(spacing: 10) {
                Link("View on GitHub \u{2197}", destination: URL(string: "https://github.com/noomz/agents-usage-bar")!)
                    .font(.body)

                Link("License (MIT) \u{2197}", destination: URL(string: "https://github.com/noomz/agents-usage-bar/blob/main/LICENSE")!)
                    .font(.body)
            }

            Divider()

            CLIAboutStatus()

            Divider()

            VStack(spacing: 4) {
                Button("Check for Updates…") { updateCheck.check() }
                    .disabled(!updateCheck.canCheck)
                if let last = updateCheck.lastCheck {
                    Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 300)
    }
}

/// Mirrors Sparkle's KVO-observable `canCheckForUpdates` so the button is disabled
/// while a check or update session is already running.
@MainActor @Observable
private final class UpdateCheck {
    private let updater: SPUUpdater
    private(set) var canCheck: Bool
    private(set) var lastCheck: Date?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(updater: SPUUpdater) {
        self.updater = updater
        canCheck = updater.canCheckForUpdates
        lastCheck = updater.lastUpdateCheckDate
        let refresh: @Sendable (SPUUpdater) -> Void = { [weak self] updater in
            let canCheck = updater.canCheckForUpdates
            let lastCheck = updater.lastUpdateCheckDate
            Task { @MainActor in
                self?.canCheck = canCheck
                self?.lastCheck = lastCheck
            }
        }
        observations = [
            updater.observe(\.canCheckForUpdates) { updater, _ in refresh(updater) },
            updater.observe(\.lastUpdateCheckDate) { updater, _ in refresh(updater) },
        ]
    }

    func check() {
        updater.checkForUpdates()
    }
}

private struct CLIAboutStatus: View {
    private var status: CLIInstallStatus { CLIInstaller().status() }

    var body: some View {
        VStack(spacing: 4) {
            switch status {
            case .installed(let path):
                Text("CLI installed at \(path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .repairNeeded:
                Text("CLI symlink needs repair — open Settings → General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .notInstalled:
                Text("Install the `aub` CLI from Settings → General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

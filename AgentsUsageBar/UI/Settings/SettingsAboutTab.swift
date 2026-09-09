import SwiftUI

/// Settings → About tab.
///
/// Shows app version + build, GitHub repo link, and license link.
/// Phase 6 placeholder: "Check for Updates" button (Sparkle wiring deferred to Phase 6 REL-02).
struct SettingsAboutTab: View {

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

            // Phase 6 placeholder — Sparkle "Check for Updates" wiring
            // TODO(Phase 6 REL-02): replace this Text with a Sparkle SPUUpdater button.
            Text("Automatic updates available in a future release.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 300)
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

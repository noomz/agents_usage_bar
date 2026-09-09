import SwiftUI

/// Settings → General → Command Line. Installs a symlink named `aub` onto PATH.
struct CLIInstallSection: View {
    @State private var status: CLIInstallStatus = .notInstalled
    @State private var pathHint: String?
    @State private var lastError: String?
    @State private var isWorking = false

    var body: some View {
        Section("Command Line") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    statusLabel
                    Spacer()
                    Button(status.buttonTitle) { perform() }
                        .font(.caption)
                        .disabled(isWorking)
                }
                Text(status.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let pathHint {
                    Text(pathHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { refresh() }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .repairNeeded:
            Label("Needs repair", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .notInstalled:
            Label("Not installed", systemImage: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        let installer = CLIInstaller()
        status = installer.status()
        pathHint = installer.pathHint()
    }

    private func perform() {
        isWorking = true
        lastError = nil
        let current = status
        Task.detached(priority: .userInitiated) {
            let installer = CLIInstaller()
            do {
                switch current {
                case .installed:
                    try installer.uninstall()
                case .notInstalled, .repairNeeded:
                    _ = try installer.install()
                }
                await MainActor.run {
                    refresh()
                    isWorking = false
                }
            } catch {
                await MainActor.run {
                    lastError = error.localizedDescription
                    refresh()
                    isWorking = false
                }
            }
        }
    }
}

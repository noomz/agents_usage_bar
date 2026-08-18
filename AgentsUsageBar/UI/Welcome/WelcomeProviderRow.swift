import SwiftUI
import AppKit

/// A single provider row in the Welcome window.
///
/// Shows: provider name, detection badge (Checking… / Detected / Not running /
/// Not configured / Not detected), and an expandable "How to enable" help panel
/// for undetected/unconfigured providers (D-14).
struct WelcomeProviderRow: View {

    let providerID: ProviderID
    let detectionResult: DetectionResult?
    let isProbing: Bool
    let onboardingInfo: ProviderOnboardingInfo?

    @State private var isExpanded: Bool = false
    @State private var copiedEnv: Bool = false
    @State private var copiedToml: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // Provider icon — SF Symbol best-effort per provider
                Image(systemName: iconName)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)

                // Name + badge
                VStack(alignment: .leading, spacing: 2) {
                    Text(providerID.displayHint)
                        .fontWeight(.medium)
                    detectionBadge
                }

                Spacer()

                // Disclosure chevron for undetected/unconfigured providers
                if shouldShowHelpPanel {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isExpanded ? "Hide setup instructions" : "Show setup instructions")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Expandable help panel (D-14)
            if isExpanded, let info = onboardingInfo {
                VStack(alignment: .leading, spacing: 8) {
                    Text(info.detectionDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Env var snippet
                    snippetBlock(
                        label: "Environment variable",
                        snippet: info.envSnippet,
                        note: info.envNote,
                        copied: $copiedEnv
                    )

                    // TOML snippet
                    snippetBlock(
                        label: "config.toml",
                        snippet: info.tomlSnippet,
                        note: info.tomlNote,
                        copied: $copiedToml
                    )

                    // Docs link
                    if let docsURL = info.docsURL, let url = URL(string: docsURL) {
                        Link("Open docs \u{2197}", destination: url)
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Helpers

    private var shouldShowHelpPanel: Bool {
        guard onboardingInfo != nil else { return false }
        switch detectionResult {
        case .notDetected, .notConfigured, .notRunning, nil:
            return true
        case .detected:
            return false
        }
    }

    @ViewBuilder
    private var detectionBadge: some View {
        if isProbing {
            Text("Checking\u{2026}")
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
                Text("\u{2014}")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var iconName: String {
        switch providerID {
        case .openrouter: return "network"
        case .claude:     return "brain"
        case .codex:      return "chevron.left.forwardslash.chevron.right"
        case .gemini:     return "sparkles"
        case .grok:       return "bolt.horizontal"
        case .ollama:     return "desktopcomputer"
        case .lmstudio:   return "display"
        case .llamacpp:   return "cpu"
        default:          return "cpu"
        }
    }

    @ViewBuilder
    private func snippetBlock(
        label: String,
        snippet: String,
        note: String,
        copied: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(copied.wrappedValue ? "Copied!" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied.wrappedValue = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied.wrappedValue = false
                    }
                }
                .font(.caption2)
                .buttonStyle(.borderless)
            }
            Text(snippet)
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .cornerRadius(4)
            Text(note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

import SwiftUI

/// SwiftUI root view for the first-run Welcome window.
///
/// On appear: fires `DetectionProbe.probeAll` in parallel for all 7 providers,
/// then seeds `UserPreferencesStore.providerEnabled` for detected providers (D-11 + CFG-03).
///
/// D-13: detection is pre-computed during welcome load, NOT during `AppDependencies.makeProduction()`.
/// The composition root stays fast; 2s perceived welcome latency is acceptable for a one-time screen.
struct WelcomeRootView: View {

    let preferences: UserPreferencesStore
    let config: AppConfig
    let onDismiss: (_ openSettings: Bool) -> Void

    @State private var detectionResults: [ProviderID: DetectionResult] = [:]
    @State private var isProbing: Bool = true
    @State private var onboardingCopy: OnboardingCopy? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 24)

                Text("Welcome to Agents Usage Bar")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("The app detected the following AI providers on your system.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.bottom, 16)

            Divider()

            // Provider list
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ProviderID.allKnown, id: \.rawValue) { id in
                        WelcomeProviderRow(
                            providerID: id,
                            detectionResult: detectionResults[id],
                            isProbing: isProbing,
                            onboardingInfo: onboardingCopy?.providers.first { $0.providerID == id.rawValue }
                        )
                        if id != ProviderID.allKnown.last {
                            Divider()
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)

            Divider()

            // Footer
            HStack {
                Spacer()

                Button("Open Settings") {
                    onDismiss(true)
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Get Started") {
                    onDismiss(false)
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 520, height: 480)
        .onAppear {
            loadCopy()
            Task { await runProbes() }
        }
    }

    // MARK: - Private

    private func loadCopy() {
        onboardingCopy = try? OnboardingCopy.loadBundled()
    }

    private func runProbes() async {
        isProbing = true
        // Re-create a 2s HTTPClient — one-time cost, acceptable for welcome screen (D-13).
        // Does NOT reuse the production localhostHTTP to avoid adding it to the Dependencies bag.
        let http = URLSessionHTTPClient(timeoutSeconds: 2)
        let results = await DetectionProbe.probeAll(
            config: config,
            localhostHTTP: http
        )
        detectionResults = results
        isProbing = false

        // CFG-03 + D-11: seed detected providers as enabled in UserDefaults (first-run only).
        // Only set providers for keys that have never been explicitly set — preserves user
        // choices on subsequent probes. providerEnabled[id] == nil means never set.
        for (id, result) in results where result == .detected {
            if preferences.providerEnabled[id] == nil {
                preferences.setProviderEnabled(id, enabled: true)
            }
        }
    }
}

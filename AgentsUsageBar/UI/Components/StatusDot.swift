import SwiftUI

/// A colored 8×8 circle indicating the operational status of a provider.
///
/// Color mapping (from `ProviderStatus` enum):
///   - `.ok(_)`             → green  (last fetch succeeded)
///   - `.stale(_, _)`       → yellow (data is stale — prior success exists but fetch failed)
///   - `.error(_)`          → red    (fetch failed, no prior success)
///   - `.unauthenticated`   → gray   (no API key configured or key rejected)
///   - `.notRunning`        → gray   (localhost runtime not listening — muted, never red; Plan 04-01 / LOCAL-04)
///   - `.disabled`          → gray dimmed (explicitly disabled by user)
///
/// Plan 02.07 (UI-08): the `isStale` flag dims the dot to 40% opacity when the
/// store reports the provider as stale (no successful refresh within 2× the
/// current refresh interval). The semantic status colour is preserved; only
/// the alpha changes so the user notices the data is older than expected.
///
/// Plan 03-07 (D-11): the `forceAmber` flag overrides the semantic status
/// colour with `.orange` so Gemini's "usage-temporarily-unavailable" snapshot
/// (Plan 03-06) renders as an amber dot rather than red — the v1internal
/// endpoint is documented unstable; red would be false alarm fatigue. The
/// stale dimming still composes on top of the amber tint.
public struct StatusDot: View {
    public let status: ProviderStatus
    public let isStale: Bool
    public let forceAmber: Bool

    /// Plan 02.07 + Plan 03-07 — additive parameters. Defaults preserve every
    /// existing Phase 1/2 call site.
    public init(status: ProviderStatus, isStale: Bool = false, forceAmber: Bool = false) {
        self.status = status
        self.isStale = isStale
        self.forceAmber = forceAmber
    }

    // MARK: - View body

    public var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Helpers

    private var dotColor: Color {
        // Base colour per ProviderStatus.
        let base: Color
        switch status {
        case .ok:
            base = .green
        case .stale:
            base = .yellow
        case .error:
            base = .red
        case .unauthenticated:
            base = .gray
        case .notRunning:
            base = .gray
        case .disabled:
            return .gray.opacity(0.4)  // .disabled already encodes its own dim
        }
        // Plan 03-07 (D-11): forceAmber overrides the semantic colour so the
        // degraded UX (Gemini "usage-temporarily-unavailable") renders amber
        // rather than red/green/yellow.
        let resolved: Color = forceAmber ? .orange : base
        // UI-08: stale dimming composes on top.
        return isStale ? resolved.opacity(0.4) : resolved
    }

    private var accessibilityLabel: String {
        let suffix = isStale ? " (stale)" : ""
        switch status {
        case .ok:
            return "Status: OK" + suffix
        case .stale:
            return "Status: Stale data" + suffix
        case .error:
            return "Status: Error" + suffix
        case .unauthenticated:
            return "Status: Not authenticated" + suffix
        case .notRunning:
            return "Status: Not running" + suffix
        case .disabled:
            return "Status: Disabled" + suffix
        }
    }
}

// MARK: - Previews

#Preview("StatusDot — ok (green)") {
    StatusDot(status: .ok(lastSuccess: .now))
        .padding()
}

#Preview("StatusDot — stale (yellow)") {
    StatusDot(status: .stale(lastSuccess: .now.addingTimeInterval(-300), error: ProviderError(kind: .network, message: "timeout")))
        .padding()
}

#Preview("StatusDot — error (red)") {
    StatusDot(status: .error(ProviderError(kind: .network, message: "Connection refused")))
        .padding()
}

#Preview("StatusDot — unauthenticated (gray)") {
    StatusDot(status: .unauthenticated)
        .padding()
}

#Preview("StatusDot — notRunning (gray)") {
    StatusDot(status: .notRunning)
        .padding()
}

#Preview("StatusDot — disabled (dim gray)") {
    StatusDot(status: .disabled)
        .padding()
}

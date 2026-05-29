import SwiftUI

/// A colored 8×8 circle indicating the operational status of a provider.
///
/// Color mapping (from `ProviderStatus` enum):
///   - `.ok(_)`             → green  (last fetch succeeded)
///   - `.stale(_, _)`       → yellow (data is stale — prior success exists but fetch failed)
///   - `.error(_)`          → red    (fetch failed, no prior success)
///   - `.unauthenticated`   → gray   (no API key configured or key rejected)
///   - `.disabled`          → gray dimmed (explicitly disabled by user)
///
/// Plan 02.07 (UI-08): the `isStale` flag dims the dot to 40% opacity when the
/// store reports the provider as stale (no successful refresh within 2× the
/// current refresh interval). The semantic status colour is preserved; only
/// the alpha changes so the user notices the data is older than expected.
public struct StatusDot: View {
    public let status: ProviderStatus
    public let isStale: Bool

    /// Plan 02.07 — additive overload accepting the `isStale` flag from
    /// `AggregateStore.isStale(_:now:)`. The default `false` preserves Phase 1
    /// call-site compatibility.
    public init(status: ProviderStatus, isStale: Bool = false) {
        self.status = status
        self.isStale = isStale
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
        case .disabled:
            return .gray.opacity(0.4)  // .disabled already encodes its own dim
        }
        // UI-08: stale dimming on top of the semantic colour.
        return isStale ? base.opacity(0.4) : base
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

#Preview("StatusDot — disabled (dim gray)") {
    StatusDot(status: .disabled)
        .padding()
}

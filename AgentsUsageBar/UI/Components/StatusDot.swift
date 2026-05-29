import SwiftUI

/// A colored 8×8 circle indicating the operational status of a provider.
///
/// Color mapping (from `ProviderStatus` enum):
///   - `.ok(_)`             → green  (last fetch succeeded)
///   - `.stale(_, _)`       → yellow (data is stale — prior success exists but fetch failed)
///   - `.error(_)`          → red    (fetch failed, no prior success)
///   - `.unauthenticated`   → gray   (no API key configured or key rejected)
///   - `.disabled`          → gray dimmed (explicitly disabled by user)
public struct StatusDot: View {
    public let status: ProviderStatus

    public init(status: ProviderStatus) {
        self.status = status
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
        switch status {
        case .ok:
            return .green
        case .stale:
            return .yellow
        case .error:
            return .red
        case .unauthenticated:
            return .gray
        case .disabled:
            return .gray.opacity(0.4)
        }
    }

    private var accessibilityLabel: String {
        switch status {
        case .ok:
            return "Status: OK"
        case .stale:
            return "Status: Stale data"
        case .error:
            return "Status: Error"
        case .unauthenticated:
            return "Status: Not authenticated"
        case .disabled:
            return "Status: Disabled"
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

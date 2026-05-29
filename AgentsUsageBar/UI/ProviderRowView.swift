import SwiftUI

/// Placeholder per-provider row for the Walking Skeleton.
///
/// Displays the provider's display name and placeholder message.
/// Fixed `.frame(height: 44)` gives MenuBarExtra a deterministic first-frame layout
/// (Pitfall 1 mitigation: "Give every row an intrinsic height").
///
/// Plan 01.06 replaces this with the real row: tokens used, USD spent,
/// colored quota bar, "Updated Xs ago" timestamp, and error/stale states.
public struct ProviderRowView: View {
    public let state: ProviderState

    public var body: some View {
        HStack {
            Text(state.displayName)
                .font(.headline)
            Spacer()
            Text(state.placeholderMessage ?? "—")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

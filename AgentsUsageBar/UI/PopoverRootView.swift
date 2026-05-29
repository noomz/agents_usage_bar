import SwiftUI

/// Root view of the `MenuBarExtra(.window)` popover panel.
///
/// Fixed at 360pt width (Pitfall 1 mitigation: explicit fixed width prevents
/// MenuBarExtra from sizing to an indeterminate intrinsic size on first appearance).
/// Plan 01.06 ships the real per-provider rows, quota bars, totals header,
/// "Updated Xs ago" label, and Cmd-R manual refresh.
public struct PopoverRootView: View {
    @Environment(AggregateStore.self) private var store

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.providers.values), id: \.id) { state in
                ProviderRowView(state: state)
            }
            Divider()
            FooterView()
        }
        .frame(width: 360)
        .padding(.vertical, 8)
    }
}

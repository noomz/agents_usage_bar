import AppKit
import SwiftUI

/// Root view of the `MenuBarExtra(.window)` popover panel (UI-01, UI-07, SHELL-04).
///
/// Fixed at 360pt width (SHELL-04; Pitfall 1 mitigation: explicit fixed width prevents
/// `MenuBarExtra` from sizing to an indeterminate intrinsic size on first appearance).
///
/// Layout:
///   TotalsHeaderView   ← summed tokens + USD (UI-01)
///   Divider
///   ProviderRowView    ← one per provider, in `provider-order` (SPEC V32)
///   Divider
///   FooterView         ← Refresh now (Cmd-R) + Quit (Cmd-Q)
///
/// UI-07 guarantee: `AggregateStore.init` seeds `providers` from cache synchronously, so
/// this view renders cached values IMMEDIATELY on first open — no "Loading…" flash.
///
/// Visibility: `MenuBarExtra(.window)` usually rebuilds this view on each open, but a
/// long-running process was seen keeping it mounted while the panel was ordered out,
/// ticking every second off screen. The view therefore also watches its window's
/// occlusion state: the rows' clock ticks only while the panel is on screen, and each
/// open triggers a refresh.
///
/// Uses `@Environment(AggregateStore.self)` (Observation framework, macOS 14+).
/// No `@StateObject`, `ObservableObject`, `@Published`, or `import Combine`.
public struct PopoverRootView: View {
    @Environment(AggregateStore.self) private var store
    @Environment(\.clockService) private var clock
    @Environment(\.popoverTeaserSource) private var teaserSource
    @State private var window: NSWindow?
    @State private var teaser: PopoverTeaser?
    /// Starts `true`: the view mounts because the popover is opening.
    @State private var isVisible = true

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TotalsHeaderView()
            Divider()
            ProviderListView(isVisible: isVisible)
            Divider()
            if let teaser {
                PopoverTeaserView(teaser: teaser)
                Divider()
            }
            FooterView()
        }
        .frame(width: 360)
        .textSelection(.disabled)
        .background(HostingWindowReader { window = $0 })
        .task(id: window.map(ObjectIdentifier.init)) {
            await trackVisibility(of: window)
        }
        // POLL-03: refresh on every popover open (coalesced if within 5s of last tick).
        // Kept out of the row clock's task so a slow fetch never stalls the timestamps.
        .task(id: isVisible) {
            guard isVisible else { return }
            await store.refresh(now: clock.now())
        }
        // V20: history is read on popover open only, never on the poll path.
        .task(id: isVisible) {
            guard isVisible, let teaserSource else { return }
            teaser = await teaserSource.load()
        }
    }

    private func trackVisibility(of window: NSWindow?) async {
        guard let window else { return }
        isVisible = window.occlusionState.contains(.visible)
        // Bridged through `AsyncStream<Void>` rather than `notifications(named:)`, whose
        // non-Sendable `Notification` elements Swift 6.1 rejects on the main actor.
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { _ in continuation.yield() }
        defer { NotificationCenter.default.removeObserver(token) }
        for await _ in changes {
            isVisible = window.occlusionState.contains(.visible)
        }
    }

    nonisolated static func ordered(_ states: [ProviderState], preference: [ProviderID]) -> [ProviderState] {
        ProviderID.ordered(states, id: \.id, preference: preference)
    }
}

/// The provider rows plus the popover's one-second clock. The clock lives here, not in
/// `PopoverRootView`, so each tick re-evaluates only the rows.
private struct ProviderListView: View {
    let isVisible: Bool
    @Environment(AggregateStore.self) private var store
    @Environment(\.clockService) private var clock
    @State private var now = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sortedProviderStates().enumerated()), id: \.element.id) { idx, state in
                if idx > 0 { Divider() }
                ProviderRowView(state: state, now: now)
            }
        }
        // Ticks only while the panel is on screen. A state write while hidden would still
        // lay out and commit the ordered-out window.
        .task(id: isVisible) {
            guard isVisible else { return }
            let ticker = ContinuousClock()
            var next = ticker.now
            while true {
                now = clock.now()
                next += .seconds(1)
                do {
                    try await ticker.sleep(until: next, tolerance: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    /// Rows in the user's `provider-order`, read on each render so a changed
    /// setting shows on the next popover open.
    private func sortedProviderStates() -> [ProviderState] {
        PopoverRootView.ordered(Array(store.providers.values), preference: UserDefaults.standard.aubProviderOrder)
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view, each time the view attaches to one.
private struct HostingWindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        ReportingView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReportingView: NSView {
        let onWindow: @MainActor (NSWindow?) -> Void

        init(onWindow: @escaping @MainActor (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Deferred: this runs inside a SwiftUI update, where writing state is unsupported.
            let window = window
            Task { @MainActor in onWindow(window) }
        }
    }
}

// MARK: - Preview

#Preview("PopoverRootView — with OpenRouter placeholder") {
    let store = AggregateStore(
        registry: [],
        clock: SystemClock(),
        cache: NoopCacheStore(),
        thresholds: ThresholdEngine(),
        notifications: NoopNotificationManager()
    )
    store.seedPlaceholder(
        providerID: ProviderID(rawValue: "openrouter"),
        displayName: "OpenRouter",
        status: .unauthenticated
    )
    return PopoverRootView()
        .environment(store)
}

import SwiftUI
import AppKit

/// Popover footer with "Refresh now" (Cmd-R) and "Quit Agents Usage Bar" (Cmd-Q) buttons.
///
/// Satisfies:
/// - UI-10: Manual "Refresh now" button with Cmd-R keyboard shortcut
/// - SHELL-06: Quit action available from popover footer
///
/// CRITICAL (B5): This file CONSUMES `\.clockService` via `@Environment` only.
/// `ClockKey` and `EnvironmentValues.clockService` are declared SOLELY in
/// `UI/Environment/ClockEnvironmentKey.swift` (Plan 01.06). Do NOT redeclare here.
/// Plan 01.08 INJECTS via `.environment(\.clockService, dependencies.clock)`.
public struct FooterView: View {
    @Environment(AggregateStore.self) private var store
    @Environment(\.clockService) private var clock
    // SHELL-05: Apple-supported action to open the SwiftUI `Settings` scene. Works on
    // LSUIElement apps where the legacy `showSettingsWindow:` selector dispatch fails
    // silently (the responder chain has no key window to receive the action).
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
        // Plan 02.07 (UI-05): the footer now stacks a small "Resets HH:mm <TZ>" caption
        // above the action buttons so the user knows exactly when the today aggregation
        // window resets (local midnight, DST-correct via Calendar.current).
        VStack(spacing: 4) {
            HStack {
                Text(TodayHelper.resetClockText(clock.now()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)

            HStack(spacing: 8) {
                Button {
                    Task {
                        await store.refresh(now: clock.now())
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .buttonStyle(HoverableBorderedButtonStyle())
                .tint(.accentColor)

                Button {
                    // Open the native Settings window from the menu-bar popover (SHELL-05).
                    // LSUIElement apps have no app menu, so the popover is the only
                    // discoverable entry point. Activate first so the window gets key
                    // focus, then use the SwiftUI openSettings action.
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .buttonStyle(HoverableBorderedButtonStyle())

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
                .buttonStyle(HoverableBorderedButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Preview

#Preview("FooterView") {
    let store = AggregateStore(
        registry: [],
        clock: SystemClock(),
        cache: NoopCacheStore(),
        thresholds: ThresholdEngine(),
        notifications: NoopNotificationManager()
    )
    return FooterView()
        .environment(store)
        .frame(width: 360)
}

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

    public init() {}

    public var body: some View {
        HStack(spacing: 12) {
            Button("Refresh now") {
                Task {
                    await store.refresh(now: clock.now())
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)

            Spacer()

            Button("Quit Agents Usage Bar") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 36)
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

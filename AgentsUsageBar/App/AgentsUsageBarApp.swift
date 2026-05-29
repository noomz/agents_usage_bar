import SwiftUI
import AppKit
import UserNotifications

@main
struct AgentsUsageBarApp: App {
    /// Composition root — holds the store, scheduler, and clock for the app lifetime.
    /// `@State` is correct: `Dependencies` is a reference type whose `store` is `@Observable`,
    /// so SwiftUI tracks mutations without `@StateObject`/`ObservableObject`.
    @State private var dependencies: Dependencies = AppDependencies.makeProduction()

    init() {
        // Defensive belt-and-braces alongside Info.plist LSUIElement=YES (SHELL-01 / Pitfall 2).
        // Ensures no Dock icon and no Cmd-Tab entry regardless of how the app is launched.
        NSApplication.shared.setActivationPolicy(.accessory)

        // Plan 02.05 — Pitfall 6: register the `usage.warning` notification category +
        // `snooze.today` action BEFORE the first UNUserNotificationCenter.add() call.
        // Categories registered after the first add() are not applied to that request.
        UNNotificationManager.registerCategories(on: UNUserNotificationCenter.current())
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView()
                .environment(dependencies.store)
                .environment(\.clockService, dependencies.clock)   // B5: only INJECT; key declared in Plan 01.06
                .task {
                    // Plan 02.05 — install snooze action handler BEFORE the poll loop starts
                    // so any notification fired by the first refresh has its action wired.
                    UNUserNotificationCenter.current().delegate = dependencies.actionHandler
                    // Plan 02.06 — Pitfall 4: force-realize the PowerObserver strong reference
                    // BEFORE scheduler.start() so the willSleep/didWake observers are live
                    // before any wake event the polling loop could race with.
                    _ = dependencies.powerObserver
                    // Kick off the long-lived PollScheduler loop on first popover open.
                    // Cancelled automatically when the scene tears down (structured concurrency).
                    await dependencies.scheduler.start()
                }
        } label: {
            // Plan 02.07 (UI-09 + Pitfall 9): the menu bar icon tints to reflect the
            // highest quota fraction across all providers (green < 0.80, yellow 0.80–0.95,
            // red >= 0.95). `@Observable` re-renders this label automatically when
            // `dependencies.store.maxQuotaFraction` changes. Snap transition (no animation)
            // is acceptable per RESEARCH §H.3.
            Image(systemName: "chart.bar.doc.horizontal")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(dependencies.store.menuBarTint)
                .accessibilityLabel("Agents Usage Bar")
        }
        .menuBarExtraStyle(.window)   // SHELL-04 — rich SwiftUI popover (not .menu)
    }
}

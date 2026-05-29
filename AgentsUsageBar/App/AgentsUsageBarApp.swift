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
        MenuBarExtra("Agents Usage Bar", systemImage: "chart.bar.doc.horizontal") {
            PopoverRootView()
                .environment(dependencies.store)
                .environment(\.clockService, dependencies.clock)   // B5: only INJECT; key declared in Plan 01.06
                .task {
                    // Plan 02.05 — install snooze action handler BEFORE the poll loop starts
                    // so any notification fired by the first refresh has its action wired.
                    UNUserNotificationCenter.current().delegate = dependencies.actionHandler
                    // Kick off the long-lived PollScheduler loop on first popover open.
                    // Cancelled automatically when the scene tears down (structured concurrency).
                    await dependencies.scheduler.start()
                }
        }
        .menuBarExtraStyle(.window)   // SHELL-04 — rich SwiftUI popover (not .menu)
    }
}

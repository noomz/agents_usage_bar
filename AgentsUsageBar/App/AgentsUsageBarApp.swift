import SwiftUI
import AppKit

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
    }

    var body: some Scene {
        MenuBarExtra("Agents Usage Bar", systemImage: "chart.bar.doc.horizontal") {
            PopoverRootView()
                .environment(dependencies.store)
                .environment(\.clockService, dependencies.clock)   // B5: only INJECT; key declared in Plan 01.06
                .task {
                    // Kick off the long-lived PollScheduler loop on first popover open.
                    // Cancelled automatically when the scene tears down (structured concurrency).
                    await dependencies.scheduler.start()
                }
        }
        .menuBarExtraStyle(.window)   // SHELL-04 — rich SwiftUI popover (not .menu)
    }
}

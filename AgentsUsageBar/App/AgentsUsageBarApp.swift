import SwiftUI
import AppKit

@main
struct AgentsUsageBarApp: App {
    /// Composition root — holds the store and all collaborators for the lifetime of the app.
    /// `@State` is correct here: `AppDependencies.Container` is a value type whose `store`
    /// property is an `@Observable` reference type, so SwiftUI tracks it properly.
    @State private var dependencies = AppDependencies.makeProduction()

    init() {
        // Belt-and-braces alongside LSUIElement=YES (Pitfall 2 mitigation):
        // ensures the app never enters the foreground activation policy even if
        // Info.plist is overridden or the app is launched programmatically.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Agents Usage Bar", systemImage: "chart.bar.doc.horizontal") {
            PopoverRootView()
                .environment(dependencies.store)
        }
        .menuBarExtraStyle(.window)
    }
}

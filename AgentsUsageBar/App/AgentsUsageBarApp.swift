import SwiftUI
import AppKit
import UserNotifications
import Sparkle

/// Issue #18 — owns the composition root and starts background services at launch.
/// `MenuBarExtra(.window)` only builds its content on first popover open, so startup
/// cannot live in a `.task` there.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Composition root — holds the store, scheduler, and clock for the app lifetime.
    let dependencies: Dependencies

    override init() {
        dependencies = AppDependencies.makeProduction()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The unit-test bundle is hosted in this app; don't start real polling,
        // notification routing, or the Welcome window under the test runner.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { await dependencies.startBackgroundServices() }
    }
}

struct AgentsUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// `Dependencies` is a reference type whose `store` is `@Observable`, so SwiftUI
    /// tracks mutations without `@StateObject`/`ObservableObject`.
    private var dependencies: Dependencies { appDelegate.dependencies }

    /// Plan 06-02 (REL-06) — Sparkle auto-update controller. Started immediately at launch
    /// so the updater polls `SUFeedURL` (Info.plist) on its standard schedule and verifies any
    /// downloaded DMG against `SUPublicEDKey`. Stored as a `private let` so the controller
    /// (and its underlying SPUUpdater) lives for the entire app lifetime — Sparkle requires
    /// the controller to outlive the launch transient.
    private let updaterController: SPUStandardUpdaterController

    init() {
        // Defensive belt-and-braces alongside Info.plist LSUIElement=YES (SHELL-01 / Pitfall 2).
        // Ensures no Dock icon and no Cmd-Tab entry regardless of how the app is launched.
        NSApplication.shared.setActivationPolicy(.accessory)

        // Plan 02.05 — Pitfall 6: register the `usage.warning` notification category +
        // `snooze.today` action BEFORE the first UNUserNotificationCenter.add() call.
        // Categories registered after the first add() are not applied to that request.
        UNNotificationManager.registerCategories(on: UNUserNotificationCenter.current())

        // Plan 06-02 (REL-06) — instantiate Sparkle's standard updater controller with the
        // updater started immediately. `userDriverDelegate = nil` accepts Sparkle's default
        // user-facing UI (the standard "A new version is available" sheet); a custom UI is
        // out of scope for this plan. `updaterDelegate = nil` accepts default policy.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView()
                .environment(dependencies.store)
                .environment(\.clockService, dependencies.clock)   // B5: only INJECT; key declared in Plan 01.06
                .environment(\.preferences, dependencies.preferences)  // Plan 05-02: preferences overlay (D-01/D-02)
                // Plan 05-03 D-04: apply theme live at root so all windows flip in unison.
                .preferredColorScheme(dependencies.preferences.theme.colorScheme)
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

        // Plan 05-01 — SwiftUI Settings scene (D-05 / D-07 / SHELL-05).
        // Hosts the three-tab Settings UI scaffold; tab bodies are filled by Plans 05-03
        // (General), 05-04 (Providers), 05-06 (About). SwiftUI auto-binds Cmd-, to open
        // this scene; the CommandGroup(replacing: .appSettings) below injects
        // NSApp.activate(...) so the window comes to front and gets key status on
        // LSUIElement apps (D-05 / Pitfall 1).
        Settings {
            SettingsScene()
                .environment(dependencies.store)
                .environment(\.clockService, dependencies.clock)
                .environment(\.preferences, dependencies.preferences)  // Plan 05-02: preferences overlay (D-01/D-02)
                // Plan 05-03 D-04: theme applies to Settings window too.
                .preferredColorScheme(dependencies.preferences.theme.colorScheme)
        }
        .commands {
            // Plan 05-01 — LSUIElement Cmd-, focus fix (D-05 / Pitfall 1). The default
            // SwiftUI Settings command does NOT call NSApp.activate(ignoringOtherApps:),
            // so on LSUIElement apps the window may open without key focus. Replacing the
            // .appSettings command group lets us call activate() before SwiftUI fires the
            // standard show-settings selector down the responder chain.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    // Programmatically dispatch the standard Settings action down the
                    // responder chain. On macOS 14+ the modern selector is
                    // `showSettingsWindow:`; the legacy `showPreferencesWindow:` remains
                    // for older OS dot-revisions where the responder chain has not yet
                    // adopted the new name.
                    if NSApp.responds(to: Selector(("showSettingsWindow:"))) {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } else {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

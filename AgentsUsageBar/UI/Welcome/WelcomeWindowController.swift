import AppKit
import SwiftUI

/// Hosts the first-run Welcome window.
///
/// Activation-policy flip (SHELL-05 + D-06): This controller does NOT call
/// `NSApp.setActivationPolicy` directly. The `WindowActivationObserver` (Plan 05-01)
/// is the single source of truth — it listens for `NSWindow.didBecomeKeyNotification`
/// for windows whose title is in `managedTitles = ["Settings", "Welcome"]`. Opening
/// this window fires `didBecomeKey`, which increments the observer's counter and flips
/// policy to `.regular`. Closing fires `willCloseNotification`, decrementing the counter;
/// policy reverts to `.accessory` only when all managed windows are closed (ISS-04).
///
/// Observer lifetime (Pitfall 4): the `NSWindow.willCloseNotification` observer token is
/// held strongly in `self` and removed in `deinit`, mirroring `PowerObserver` exactly.
@MainActor
public final class WelcomeWindowController {

    // MARK: - Private state

    private var window: NSWindow?

    // Token written once in show() on @MainActor; read from nonisolated deinit.
    // nonisolated(unsafe) is required — mirrors PowerObserver pattern.
    nonisolated(unsafe) private var closeObserver: NSObjectProtocol?

    private let preferences: UserPreferencesStore
    private let config: AppConfig

    // MARK: - Init

    public init(preferences: UserPreferencesStore, config: AppConfig) {
        self.preferences = preferences
        self.config = config
    }

    deinit {
        if let token = closeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Public API

    /// Shows the Welcome window if `hasSeenWelcome` is false and the window is not already visible.
    public func showIfNeeded() {
        guard !preferences.hasSeenWelcome else { return }
        show()
    }

    /// Opens the Welcome window unconditionally (e.g., for testing or re-trigger).
    public func show() {
        // If already showing, just bring to front.
        if let existing = window, existing.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Build the NSWindow hosting a SwiftUI WelcomeRootView.
        let rootView = WelcomeRootView(
            preferences: preferences,
            config: config,
            onDismiss: { [weak self] openSettings in
                self?.dismiss(openSettings: openSettings)
            }
        )
        let hosting = NSHostingController(rootView: rootView)

        let win = NSWindow(contentViewController: hosting)
        // ISS-04: title MUST be "Welcome" so WindowActivationObserver.managedTitles
        // (["Settings", "Welcome"]) matches this window and handles the policy flip.
        // WelcomeWindowController does NOT call setActivationPolicy directly.
        win.title = "Welcome"
        win.setContentSize(NSSize(width: 520, height: 480))
        win.styleMask = [.titled, .closable]  // not resizable (D-09)
        win.isReleasedWhenClosed = false
        win.center()

        // Register close observer BEFORE showing the window (Pitfall 4).
        // Called via willCloseNotification so we also catch the red-button close.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWindowClose()
            }
        }

        window = win

        // Activate the app so the window comes to front and gets key status (D-05).
        // WindowActivationObserver handles the activation-policy flip via
        // NSWindow.didBecomeKeyNotification — no setActivationPolicy call here.
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // MARK: - Private

    private func dismiss(openSettings: Bool) {
        preferences.setHasSeenWelcome(true)
        window?.close()
        if openSettings {
            // Open the Settings window at the Providers tab.
            // Dispatch the standard Settings action down the responder chain.
            // Mirror the Cmd-, handler in AgentsUsageBarApp (Plan 05-01).
            NSApp.activate(ignoringOtherApps: true)
            if NSApp.responds(to: Selector(("showSettingsWindow:"))) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
    }

    private func handleWindowClose() {
        // Called by NSWindow.willCloseNotification observer.
        // setHasSeenWelcome is idempotent — may already be true if dismiss() was called.
        preferences.setHasSeenWelcome(true)
        // Do NOT call NSApp.setActivationPolicy here.
        // WindowActivationObserver is the single source of truth for the
        // activation-policy flip (ISS-04, D-06). It handles the flip on
        // NSWindow.willCloseNotification for windows in managedTitles.
    }
}

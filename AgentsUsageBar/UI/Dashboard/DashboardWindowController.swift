import AppKit
import SwiftUI

/// Hosts the one dashboard window (SPEC V50). The window is built on first open and released
/// on close, so nothing it decoded outlives it (V20). Its frame is saved under
/// `frameAutosaveName` and restored on the next open.
///
/// The title "Dashboard" is in `WindowActivationObserver.managedTitles`, which flips the app
/// to regular activation while the window is open; this controller never sets the policy.
@MainActor
public final class DashboardWindowController {

    static let title = "Dashboard"
    private static let frameAutosaveName = "Dashboard"

    private var window: NSWindow?
    private var hosting: NSHostingController<DashboardRootView>?

    // Written on the MainActor; read from nonisolated deinit (mirrors WelcomeWindowController).
    nonisolated(unsafe) private var closeObserver: NSObjectProtocol?

    public init() {}

    deinit {
        if let token = closeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Shows `route` in the dashboard, opening the window or bringing the open one to front.
    public func show(_ route: DashboardRoute) {
        if let window, let hosting {
            hosting.rootView = DashboardRootView(route: route)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: DashboardRootView(route: route))
        let win = NSWindow(contentViewController: hosting)
        win.title = Self.title
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 960, height: 640))
        win.contentMinSize = NSSize(width: 720, height: 480)
        if !win.setFrameUsingName(Self.frameAutosaveName) {
            win.center()
        }
        win.setFrameAutosaveName(Self.frameAutosaveName)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.release()
            }
        }

        window = win
        self.hosting = hosting
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func release() {
        if let token = closeObserver {
            NotificationCenter.default.removeObserver(token)
        }
        closeObserver = nil
        window = nil
        hosting = nil
    }
}

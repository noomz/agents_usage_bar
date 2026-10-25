import AppKit
import SwiftUI

/// Hosts the one dashboard window (SPEC V50). The window and its `DashboardModel` are built
/// on first open and released on close, so nothing it decoded outlives it (V20). Its frame is saved under
/// `frameAutosaveName` and restored on the next open.
///
/// The title "Dashboard" is in `WindowActivationObserver.managedTitles`, which flips the app
/// to regular activation while the window is open; this controller never sets the policy.
@MainActor
public final class DashboardWindowController {

    static let title = "Dashboard"
    private static let frameAutosaveName = "Dashboard"

    private let store: AggregateStore
    private let dayKeys: DayKeyOwner
    private let reader: HistoryReader

    private var window: NSWindow?
    private var model: DashboardModel?

    // Written on the MainActor; read from nonisolated deinit (mirrors WelcomeWindowController).
    nonisolated(unsafe) private var closeObserver: NSObjectProtocol?

    public init(store: AggregateStore, dayKeys: DayKeyOwner, reader: HistoryReader = HistoryReader()) {
        self.store = store
        self.dayKeys = dayKeys
        self.reader = reader
    }

    deinit {
        if let token = closeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Shows `route` in the dashboard, opening the window or bringing the open one to front.
    public func show(_ route: DashboardRoute) {
        if let window, let model {
            model.show(route)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = DashboardModel(
            route: route, reader: reader, dayKeys: dayKeys, order: UserDefaults.standard.aubProviderOrder)
        let hosting = NSHostingController(rootView: DashboardRootView(model: model, store: store))
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
        self.model = model
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func release() {
        if let token = closeObserver {
            NotificationCenter.default.removeObserver(token)
        }
        closeObserver = nil
        window = nil
        model = nil
    }
}

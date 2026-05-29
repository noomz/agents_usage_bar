import AppKit
import Foundation
import os

/// Flips `NSApplication` activation policy between `.accessory` (no Dock icon) and
/// `.regular` (Dock icon visible) based on managed-window lifecycle events.
///
/// D-06 (CONTEXT.md): Settings window opens → `.regular`; closes → `.accessory`.
/// Set-based open-window tracking so opening both Welcome + Settings simultaneously works
/// correctly, and so a window losing-and-regaining key focus does not double-increment.
///
/// **AppKit correction (Rule 1 deviation from plan text):** The plan referenced
/// `NSWindow.willOpenNotification`, which does NOT exist in AppKit (verified against
/// `NSWindow.h` in the macOS 26.5 SDK). The canonical "window appeared" signal on macOS
/// is `didBecomeKeyNotification` — fires the first time the window becomes key, which on
/// LSUIElement apps after `NSApp.activate(ignoringOtherApps:)` reliably coincides with
/// the user-visible "Settings just opened" moment. We dedupe with an ObjectIdentifier
/// Set so re-becoming-key (e.g. user clicks back into Settings after Cmd-tabbing away)
/// does NOT increment the open-count.
///
/// **Failure modes handled:**
/// - Two windows open simultaneously: Set reaches 2; only drops to `.accessory` when
///   both are closed.
/// - Window loses then regains key status: Set-based tracking prevents double-increment.
/// - Force-quit while Settings open: `willCloseNotification` does NOT fire; on next launch
///   `AgentsUsageBarApp.init()` calls `setActivationPolicy(.accessory)` which resets state.
/// - Unrelated windows (NSAlert, NSOpenPanel, MenuBarExtra popover host): filtered out by
///   the `managedTitles` allow-list.
@MainActor
public final class WindowActivationObserver {

    // MARK: - State

    /// Set of NSWindow ObjectIdentifiers currently considered "managed-open". Using a Set
    /// instead of a plain Int counter prevents double-increment when a window briefly
    /// loses and regains key status.
    private var openWindows: Set<ObjectIdentifier> = []

    // notificationCenter is a let — readable from a nonisolated deinit without
    // `nonisolated(unsafe)` because immutable let-stored properties on Sendable types
    // have no isolation barrier under Swift 6 strict concurrency.
    private let notificationCenter: NotificationCenter

    // Token vars are mutated only in init (@MainActor) and read in deinit (nonisolated).
    // `nonisolated(unsafe)` is the documented pattern (mirrors PowerObserver.swift) for
    // Swift 6 strict-concurrency-compatible deinit cleanup of non-Sendable observer tokens.
    nonisolated(unsafe) private var becomeKeyToken: NSObjectProtocol?
    nonisolated(unsafe) private var willCloseToken: NSObjectProtocol?

    private let logger = AppLogger.logger(category: "activation")

    /// Window titles that trigger the activation policy flip. Matches the SwiftUI
    /// Settings scene default title ("Settings") and the WelcomeWindowController title
    /// set in Plan 05-05 ("Welcome").
    private static let managedTitles: Set<String> = ["Settings", "Welcome"]

    // MARK: - Init

    public init(notificationCenter: NotificationCenter = NotificationCenter.default) {
        self.notificationCenter = notificationCenter

        becomeKeyToken = notificationCenter.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            Task { @MainActor [weak self] in
                self?.handleBecomeKey(window)
            }
        }

        willCloseToken = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            Task { @MainActor [weak self] in
                self?.handleWillClose(window)
            }
        }
    }

    deinit {
        if let t = becomeKeyToken  { notificationCenter.removeObserver(t) }
        if let t = willCloseToken  { notificationCenter.removeObserver(t) }
    }

    // MARK: - Test-visible state inspection

    /// Exposes the current open-window count for tests. Production callers do not need this.
    internal var openWindowCount: Int { openWindows.count }

    // MARK: - Handlers

    private func isManaged(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return Self.managedTitles.contains(window.title)
    }

    internal func handleBecomeKey(_ window: NSWindow?) {
        guard let window, isManaged(window) else { return }
        let id = ObjectIdentifier(window)
        let inserted = openWindows.insert(id).inserted
        guard inserted else { return }  // silent no-op on regained key focus
        if openWindows.count == 1 {
            NSApplication.shared.setActivationPolicy(.regular)
            logger.notice("activation → .regular (openCount=\(self.openWindows.count))")
        }
    }

    internal func handleWillClose(_ window: NSWindow?) {
        guard let window, isManaged(window) else { return }
        let id = ObjectIdentifier(window)
        let removed = openWindows.remove(id) != nil
        guard removed else { return }  // close fired for a window we never tracked
        if openWindows.isEmpty {
            NSApplication.shared.setActivationPolicy(.accessory)
            logger.notice("activation → .accessory (openCount=0)")
        }
    }
}

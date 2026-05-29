import AppKit
import Foundation
import Testing
@testable import AgentsUsageBar

/// Plan 05-01 — `WindowActivationObserver` tests.
///
/// These tests post `NSWindow.didBecomeKeyNotification` and `NSWindow.willCloseNotification`
/// against a fresh, injected `NotificationCenter` (NOT `NotificationCenter.default`) so they
/// never interfere with the real app's notifications during a parallel test run.
///
/// `.serialized` is applied because `NSApplication.shared.setActivationPolicy` is process-
/// global state and concurrent mutation across tests would race. Each test resets the
/// policy back to `.accessory` after running.
@MainActor
@Suite(.serialized)
struct WindowActivationObserverTests {

    /// Reset the global activation policy at the start/end of each test so that mutations
    /// from one test never leak into another.
    private func resetActivationPolicy() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private func makeManagedWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.title = title
        return window
    }

    /// Synchronously dispatch any pending main-actor work scheduled by the observer.
    /// `addObserver(forName:object:queue:.main, …)` schedules the user block on the main
    /// run loop; the block then awaits a `Task { @MainActor … }` hop. We yield once to
    /// let both layers complete before asserting.
    private func drainMainQueue() async {
        await Task.yield()
        await Task.yield()
    }

    @Test func singleWindowOpen_flipsToRegular() async {
        resetActivationPolicy()
        defer { resetActivationPolicy() }

        let center = NotificationCenter()
        let observer = WindowActivationObserver(notificationCenter: center)
        let window = makeManagedWindow(title: "Settings")

        observer.handleBecomeKey(window)
        await drainMainQueue()

        #expect(observer.openWindowCount == 1)
        #expect(NSApplication.shared.activationPolicy() == .regular)
    }

    @Test func singleWindowClose_flipsToAccessory() async {
        resetActivationPolicy()
        defer { resetActivationPolicy() }

        let center = NotificationCenter()
        let observer = WindowActivationObserver(notificationCenter: center)
        let window = makeManagedWindow(title: "Settings")

        observer.handleBecomeKey(window)
        observer.handleWillClose(window)
        await drainMainQueue()

        #expect(observer.openWindowCount == 0)
        #expect(NSApplication.shared.activationPolicy() == .accessory)
    }

    @Test func twoWindowsOpen_secondCloseKeepsRegular() async {
        resetActivationPolicy()
        defer { resetActivationPolicy() }

        let center = NotificationCenter()
        let observer = WindowActivationObserver(notificationCenter: center)
        let settings = makeManagedWindow(title: "Settings")
        let welcome  = makeManagedWindow(title: "Welcome")

        observer.handleBecomeKey(settings)
        observer.handleBecomeKey(welcome)
        observer.handleWillClose(welcome)
        await drainMainQueue()

        #expect(observer.openWindowCount == 1)
        #expect(NSApplication.shared.activationPolicy() == .regular)
    }

    @Test func twoWindowsOpen_bothClose_flipsToAccessory() async {
        resetActivationPolicy()
        defer { resetActivationPolicy() }

        let center = NotificationCenter()
        let observer = WindowActivationObserver(notificationCenter: center)
        let settings = makeManagedWindow(title: "Settings")
        let welcome  = makeManagedWindow(title: "Welcome")

        observer.handleBecomeKey(settings)
        observer.handleBecomeKey(welcome)
        observer.handleWillClose(settings)
        observer.handleWillClose(welcome)
        await drainMainQueue()

        #expect(observer.openWindowCount == 0)
        #expect(NSApplication.shared.activationPolicy() == .accessory)
    }

    @Test func unrelatedWindow_ignored() async {
        resetActivationPolicy()
        defer { resetActivationPolicy() }

        let center = NotificationCenter()
        let observer = WindowActivationObserver(notificationCenter: center)
        let unrelated = makeManagedWindow(title: "SomeOtherWindow")

        observer.handleBecomeKey(unrelated)
        await drainMainQueue()

        #expect(observer.openWindowCount == 0)
        #expect(NSApplication.shared.activationPolicy() == .accessory)
    }

    @Test func forceLaunchReset_policyStartsAccessory() async {
        // Simulate "app just launched": AgentsUsageBarApp.init() always resets to
        // .accessory. The observer must NOT pre-emptively flip just from being constructed.
        resetActivationPolicy()
        defer { resetActivationPolicy() }

        let center = NotificationCenter()
        let observer = WindowActivationObserver(notificationCenter: center)
        await drainMainQueue()

        #expect(observer.openWindowCount == 0)
        #expect(NSApplication.shared.activationPolicy() == .accessory)
    }

    @Test func windowRegainsKey_doesNotDoubleIncrement() async {
        // Set-based dedupe: a single window briefly losing then regaining key status
        // (e.g. user Cmd-Tabs away and back) must not increment the open-count twice.
        resetActivationPolicy()
        defer { resetActivationPolicy() }

        let center = NotificationCenter()
        let observer = WindowActivationObserver(notificationCenter: center)
        let window = makeManagedWindow(title: "Settings")

        observer.handleBecomeKey(window)
        observer.handleBecomeKey(window)  // regained key — must be a no-op
        await drainMainQueue()

        #expect(observer.openWindowCount == 1)
        #expect(NSApplication.shared.activationPolicy() == .regular)
    }

    @Test func notificationCenter_actuallyWiresHandlers() async {
        // Verify that posting via the injected NotificationCenter reaches the handler.
        // This is the integration path the real app exercises.
        resetActivationPolicy()
        defer { resetActivationPolicy() }

        let center = NotificationCenter()
        let observer = WindowActivationObserver(notificationCenter: center)
        let window = makeManagedWindow(title: "Settings")

        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        // Two yields: one to let the queue:.main observer block run, one for the
        // Task { @MainActor … } hop inside it.
        await drainMainQueue()
        await drainMainQueue()

        #expect(observer.openWindowCount == 1)
        #expect(NSApplication.shared.activationPolicy() == .regular)

        center.post(name: NSWindow.willCloseNotification, object: window)
        await drainMainQueue()
        await drainMainQueue()

        #expect(observer.openWindowCount == 0)
        #expect(NSApplication.shared.activationPolicy() == .accessory)
    }
}

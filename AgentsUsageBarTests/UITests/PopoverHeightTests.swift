import AppKit
import SwiftUI
import Testing
@testable import AgentsUsageBar

/// The `MenuBarExtra(.window)` panel takes its height from the min and max content size
/// that the hosting view sets on its window, not from the ideal size. When min and max
/// differ, the panel keeps whatever height it had, which showed as a 10pt strip.
@MainActor
@Suite("Popover panel height", .enabled(if: NSScreen.main != nil, "needs a display"))
struct PopoverHeightTests {

    private struct PanelSizing {
        let min: CGFloat
        let max: CGFloat
        let content: CGFloat
        let cap: CGFloat
        let viewport: CGFloat?
        let document: CGFloat?
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }

    private func panelSizing(providers: Int) async throws -> PanelSizing {
        let store = AggregateStore(
            registry: [],
            clock: SystemClock(),
            cache: NoopCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        for i in 0..<providers {
            store.seedPlaceholder(
                providerID: ProviderID(rawValue: "test-\(i)"),
                displayName: "Provider \(i)",
                status: .unauthenticated
            )
        }
        let host = NSHostingView(rootView: PopoverRootView().environment(store))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 10),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }
        panel.contentView = host
        panel.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        panel.layoutIfNeeded()
        let scroll = scrollView(in: host)
        return PanelSizing(
            min: panel.contentMinSize.height,
            max: panel.contentMaxSize.height,
            content: host.fittingSize.height,
            cap: try #require(panel.screen ?? NSScreen.main).visibleFrame.height * 0.8,
            viewport: scroll?.contentView.bounds.height,
            document: scroll?.documentView?.frame.height
        )
    }

    @Test("short content: panel height is pinned to the content's natural height")
    func shortContentSizesNaturally() async throws {
        let sizing = try await panelSizing(providers: 1)
        #expect(sizing.content > 10 && sizing.content < sizing.cap)
        #expect(sizing.min == sizing.max, "panel min \(sizing.min)pt, max \(sizing.max)pt")
        #expect(abs(sizing.min - sizing.content) < 1, "panel \(sizing.min)pt, content \(sizing.content)pt")
    }

    @Test("tall content: panel is pinned to 80% of the screen's visible height and scrolls")
    func tallContentIsCappedAndScrolls() async throws {
        let sizing = try await panelSizing(providers: 200)
        #expect(sizing.min == sizing.max, "panel min \(sizing.min)pt, max \(sizing.max)pt")
        #expect(abs(sizing.min - sizing.cap) < 1, "panel \(sizing.min)pt, cap \(sizing.cap)pt")
        let viewport = try #require(sizing.viewport, "no scroll view in the popover")
        let document = try #require(sizing.document)
        #expect(abs(viewport - sizing.cap) < 1, "viewport \(viewport)pt, cap \(sizing.cap)pt")
        #expect(document > viewport, "document \(document)pt, viewport \(viewport)pt")
    }
}

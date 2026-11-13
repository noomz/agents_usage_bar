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
        let window: CGFloat
        let cap: CGFloat
        let viewport: CGFloat?
        let document: CGFloat?

        /// Height outside the scroll viewport: the pinned header and footer.
        var pinned: CGFloat? { viewport.map { window - $0 } }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }

    /// A teaser source over 30 synthetic day files, so the 14-day strip shows.
    private func teaserSource() throws -> PopoverTeaserSource {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "PopoverHeightTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reader = HistoryReader(directory: dir)
        for day in SyntheticHistory.days(endingAt: "2026-10-25", count: 30) {
            try day.encoded().write(to: reader.fileURL(for: day.date))
        }
        let noonUTC = try #require(ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z"))
        let dayKeys = DayKeyOwner(
            clock: VirtualClock(fixed: noonUTC),
            timeZone: try #require(TimeZone(identifier: "UTC")),
            legacyCalendar: Calendar(identifier: .gregorian)
        )
        return PopoverTeaserSource(reader: reader, dayKeys: dayKeys)
    }

    private func panelSizing(
        providers: Int,
        flexibleContainer: Bool = false,
        withTeaser: Bool = false
    ) async throws -> PanelSizing {
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
        let teaser = withTeaser ? try teaserSource() : nil
        let host = NSHostingView(rootView: PopoverRootView().environment(store)
            .environment(\.popoverTeaserSource, teaser)
            .frame(maxHeight: flexibleContainer ? .infinity : nil))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: flexibleContainer ? 500 : 10),
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
            window: host.frame.height,
            cap: try #require(panel.screen ?? NSScreen.main).visibleFrame.height * 0.8,
            viewport: scroll?.contentView.bounds.height,
            document: scroll?.documentView?.frame.height
        )
    }

    @Test("first open: flexible container does not leave transparent margins around short content")
    func firstOpenFitsShortContent() async throws {
        let sizing = try await panelSizing(providers: 1, flexibleContainer: true)
        #expect(abs(sizing.window - sizing.content) <= 1)
        let viewport = try #require(sizing.viewport)
        let document = try #require(sizing.document)
        #expect(abs(viewport - document) <= 1, "viewport \(viewport)pt, rows \(document)pt")
    }

    @Test("popover resizes when moved between displays", .enabled(if: NSScreen.screens.count > 1, "needs two displays"))
    func movingBetweenDisplaysResizesPanel() async throws {
        let screens = NSScreen.screens.sorted { $0.visibleFrame.height > $1.visibleFrame.height }
        let store = AggregateStore(
            registry: [], clock: SystemClock(), cache: NoopCacheStore(),
            thresholds: ThresholdEngine(), notifications: NoopNotificationManager()
        )
        for i in 0..<30 {
            store.seedPlaceholder(providerID: ProviderID(rawValue: "test-\(i)"),
                                  displayName: "Provider \(i)", status: .unauthenticated)
        }
        let host = NSHostingView(rootView: PopoverRootView().environment(store)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        let panel = NSPanel(
            contentRect: NSRect(x: screens[0].visibleFrame.midX, y: screens[0].visibleFrame.minY + 20,
                                width: 360, height: screens[0].visibleFrame.height * 0.8),
            styleMask: [.nonactivatingPanel], backing: .buffered, defer: false
        )
        defer { panel.close() }
        panel.contentView = host
        try await Task.sleep(for: .milliseconds(300))
        var pinned: CGFloat?
        for screen in [screens[0], screens[1], screens[0], screens[1], screens[0]] {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.minY + 20))
            let anchoredTop = panel.frame.maxY
            try await Task.sleep(for: .milliseconds(300))
            panel.layoutIfNeeded()
            let cap = screen.visibleFrame.height * 0.8
            let viewport = try #require(scrollView(in: host)).contentView.bounds.height
            #expect(panel.screen == screen)
            #expect(!panel.isKeyWindow, "resizing must not acquire keyboard focus")
            #expect(abs(panel.frame.maxY - anchoredTop) <= 1, "resizing must preserve the menu-bar anchor")
            #expect(abs(host.frame.height - cap) <= 1)
            let outside = host.frame.height - viewport
            #expect(outside > 0, "header and footer sit outside the scroll view")
            #expect(abs(outside - (pinned ?? outside)) <= 1, "only the scroll viewport changes height")
            pinned = outside
        }
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
        let pinned = try #require(try await panelSizing(providers: 1).pinned)
        let sizing = try await panelSizing(providers: 200)
        #expect(sizing.min == sizing.max, "panel min \(sizing.min)pt, max \(sizing.max)pt")
        #expect(abs(sizing.min - sizing.cap) < 1, "panel \(sizing.min)pt, cap \(sizing.cap)pt")
        let viewport = try #require(sizing.viewport, "no scroll view in the popover")
        let document = try #require(sizing.document)
        #expect(abs(viewport - (sizing.cap - pinned)) <= 1, "viewport \(viewport)pt, cap \(sizing.cap)pt, pinned \(pinned)pt")
        #expect(document > viewport, "document \(document)pt, viewport \(viewport)pt")
    }

    @Test("tall content: header and footer stay on screen while only the rows scroll")
    func headerAndFooterStayPinned() async throws {
        let short = try #require(try await panelSizing(providers: 1).pinned)
        let tall = try #require(try await panelSizing(providers: 200).pinned)
        #expect(short > 0, "header and footer sit outside the scroll view")
        #expect(abs(tall - short) < 1, "pinned \(tall)pt with 200 rows, \(short)pt with 1 row")
    }

    @Test("tall content with the spend strip: strip is pinned and the panel stays at the cap")
    func teaserIsPinnedAboveFooter() async throws {
        let plain = try #require(try await panelSizing(providers: 200).pinned)
        let sizing = try await panelSizing(providers: 200, withTeaser: true)
        let pinned = try #require(sizing.pinned)
        #expect(pinned > plain + 10, "pinned \(pinned)pt with the strip, \(plain)pt without")
        #expect(sizing.min == sizing.max, "panel min \(sizing.min)pt, max \(sizing.max)pt")
        #expect(abs(sizing.window - sizing.cap) < 1, "panel \(sizing.window)pt, cap \(sizing.cap)pt")
    }
}

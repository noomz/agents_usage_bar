import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import AgentsUsageBar

/// SPEC V60, C5 — the optional global shortcut that opens the dashboard.
@Suite("DashboardHotkey")
@MainActor
struct DashboardHotkeyTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DashboardHotkeyTests-\(UUID().uuidString)")!
    }

    @Test("off by default (V60)")
    func offByDefault() {
        #expect(UserPreferencesStore(defaults: freshDefaults()).dashboardHotkey == nil)
    }

    @Test("a recorded shortcut persists, and Clear turns it off")
    func persists() {
        let defaults = freshDefaults()
        let hotkey = DashboardHotkey(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey), key: "D")
        UserPreferencesStore(defaults: defaults).setDashboardHotkey(hotkey)
        #expect(UserPreferencesStore(defaults: defaults).dashboardHotkey == hotkey)
        UserPreferencesStore(defaults: defaults).setDashboardHotkey(nil)
        #expect(UserPreferencesStore(defaults: defaults).dashboardHotkey == nil)
    }

    @Test("recording needs Command, Option, or Control")
    func recordingRules() throws {
        let d = UInt16(kVK_ANSI_D)
        #expect(DashboardHotkey(keyCode: d, flags: [], characters: "d") == nil)
        #expect(DashboardHotkey(keyCode: d, flags: [.shift], characters: "D") == nil)

        let hotkey = try #require(DashboardHotkey(keyCode: d, flags: [.control, .option], characters: "d"))
        #expect(hotkey.keyCode == UInt32(kVK_ANSI_D))
        #expect(hotkey.modifiers == UInt32(controlKey | optionKey))
        #expect(hotkey.display == "⌃⌥D")

        let all = try #require(DashboardHotkey(keyCode: d, flags: [.command, .shift, .option, .control], characters: "d"))
        #expect(all.display == "⌃⌥⇧⌘D")
    }

    @Test("Carbon registers and releases the shortcut without Accessibility permission (V60, C5)")
    func registers() {
        var presses = 0
        let registrar = DashboardHotkeyRegistrar(onPress: { presses += 1 })
        // F19 with every modifier: nothing on a test host holds it.
        let hotkey = DashboardHotkey(
            keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), key: "F19")
        #expect(registrar.register(hotkey))
        #expect(registrar.registered == hotkey)
        #expect(registrar.register(hotkey))
        #expect(registrar.register(nil))
        #expect(registrar.registered == nil)
        #expect(presses == 0)
    }
}

import AppKit
import Carbon.HIToolbox
import Observation
import os

/// The global shortcut that opens the dashboard (SPEC V60). Off until the user records one
/// in Settings. Stored as a Carbon key code and modifier mask for `RegisterEventHotKey` (C5).
public struct DashboardHotkey: Equatable, Codable, Sendable {
    public let keyCode: UInt32
    /// Carbon modifier mask: `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    public let modifiers: UInt32
    /// The key's label, captured when it was recorded.
    public let key: String

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// The shortcut a key press records, or nil without Command, Option, or Control: a bare
    /// or Shift-only key would steal typing from every app.
    public init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        guard modifiers != 0 else { return nil }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let label = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers, key: label.isEmpty ? "Key \(keyCode)" : label)
    }

    /// Menu-style label in the system order, such as `⌃⌥⌘D`.
    public var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }
}

/// Registers the dashboard shortcut with Carbon `RegisterEventHotKey`, which needs no
/// Accessibility permission (V60, C5). A press opens the dashboard URL (V51).
@MainActor
public final class DashboardHotkeyRegistrar {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: @MainActor () -> Void
    private let logger = AppLogger.logger(category: "hotkey")

    public init(onPress: @escaping @MainActor () -> Void = { Task { try? await DashboardRoute().open() } }) {
        self.onPress = onPress
    }

    /// The registered shortcut, nil when off.
    public private(set) var registered: DashboardHotkey?

    /// Replaces the registered shortcut; nil turns it off. Returns false when the system
    /// refuses the shortcut, for example because another app holds it.
    @discardableResult
    public func register(_ hotkey: DashboardHotkey?) -> Bool {
        // Preferences reload on every defaults write, so the same shortcut arrives often.
        if hotkey == registered { return true }
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
            registered = nil
        }
        guard let hotkey else { return true }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4155_4244), id: 1)  // 'AUBD'
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            logger.warning("RegisterEventHotKey \(hotkey.display, privacy: .public) failed: \(status)")
            return false
        }
        hotKey = ref
        registered = hotkey
        return true
    }

    /// Keeps the registration in step with Settings for the app's lifetime.
    public func follow(_ preferences: UserPreferencesStore) async {
        while !Task.isCancelled {
            register(preferences.dashboardHotkey)
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = preferences.dashboardHotkey
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let registrar = Unmanaged<DashboardHotkeyRegistrar>.fromOpaque(context).takeUnretainedValue()
            // The application event target delivers on the main thread.
            MainActor.assumeIsolated { registrar.onPress() }
            return noErr
        }, 1, &spec, context, &handler)
    }
}

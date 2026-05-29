import Foundation
import os

// MARK: - Key namespace

/// All Phase 5 UserDefaults keys. Prefix `aub.` isolates from system and third-party keys.
public enum AUBDefaultsKey {
    public static let refreshInterval = "aub.refreshInterval"  // String (RefreshInterval.rawValue)
    public static let threshold       = "aub.threshold"         // Double
    public static let theme           = "aub.theme"             // String (AppTheme.rawValue)
    public static let openAtLogin     = "aub.openAtLogin"       // Bool
    public static let hasSeenWelcome  = "aub.hasSeenWelcome"    // Bool
    /// Per-provider enabled flag: "aub.provider.<providerID.rawValue>.enabled"
    public static func providerEnabled(_ id: ProviderID) -> String {
        "aub.provider.\(id.rawValue).enabled"
    }
}

// MARK: - AppTheme

/// User-selected appearance. Stored as String rawValue in UserDefaults.
public enum AppTheme: String, Sendable, Equatable, CaseIterable {
    case light, dark, auto
}

// MARK: - UserPreferencesStore

/// `@Observable` typed wrapper over `UserDefaults`.
///
/// Stores all user-mutable knobs per D-01/D-02/D-03 (CONTEXT.md):
/// - Refresh interval, threshold, theme, open-at-login, has-seen-welcome, per-provider enabled.
/// - Credentials (API keys, OAuth tokens) are NEVER stored here (D-03, CFG-01).
///
/// Hot-reload: `UserDefaults.didChangeNotification` → `loadAll()` → `@Observable` notifies views.
@Observable
@MainActor
public final class UserPreferencesStore {

    // MARK: - Observable properties

    /// Current polling cadence. Default `.m5` per POLL-02 / CFG-05.
    public private(set) var refreshInterval: RefreshInterval = .m5

    /// Warning-band threshold fraction. Default `0.80` (80%). Range 0.5–0.95 per Discretion.
    public private(set) var threshold: Double = 0.80

    /// User-selected appearance. Default `.auto` (follow system).
    public private(set) var theme: AppTheme = .auto

    /// Open at login. Default `false` per CFG-05.
    public private(set) var openAtLogin: Bool = false

    /// Whether the first-run welcome window has been shown. Default `false`.
    public private(set) var hasSeenWelcome: Bool = false

    /// Per-provider enabled flags. Absent key = not yet explicitly set (treat as enabled for
    /// providers that exist in the registry; detection seeding sets these on first launch).
    public private(set) var providerEnabled: [ProviderID: Bool] = [:]

    // MARK: - Private

    private let defaults: UserDefaults
    // nonisolated(unsafe): written once in init (MainActor), read only in deinit (nonisolated).
    // Safe: the token write happens-before any deinit access (init completes before deinit runs).
    nonisolated(unsafe) private var changeToken: NSObjectProtocol?
    private let logger = AppLogger.logger(category: "preferences")

    // MARK: - Init

    /// Creates a store backed by the given UserDefaults suite.
    ///
    /// - Parameter defaults: Defaults suite. Pass `UserDefaults(suiteName: "test-\(UUID())")!`
    ///   in tests for full isolation. Production uses `.standard`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadAll()

        changeToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.loadAll() }
        }
    }

    deinit {
        if let t = changeToken { NotificationCenter.default.removeObserver(t) }
    }

    // MARK: - Write API (called by Settings UI via explicit setters)

    public func setRefreshInterval(_ v: RefreshInterval) {
        defaults.set(v.tomlString, forKey: AUBDefaultsKey.refreshInterval)
    }

    public func setThreshold(_ v: Double) {
        defaults.set(v, forKey: AUBDefaultsKey.threshold)
    }

    public func setTheme(_ v: AppTheme) {
        defaults.set(v.rawValue, forKey: AUBDefaultsKey.theme)
    }

    public func setOpenAtLogin(_ v: Bool) {
        defaults.set(v, forKey: AUBDefaultsKey.openAtLogin)
    }

    public func setHasSeenWelcome(_ v: Bool) {
        defaults.set(v, forKey: AUBDefaultsKey.hasSeenWelcome)
    }

    public func setProviderEnabled(_ id: ProviderID, enabled: Bool) {
        defaults.set(enabled, forKey: AUBDefaultsKey.providerEnabled(id))
    }

    // MARK: - Private load

    private func loadAll() {
        refreshInterval = RefreshInterval.parse(
            defaults.string(forKey: AUBDefaultsKey.refreshInterval) ?? ""
        ) ?? .m5

        // Use `object(forKey:) as? Double` not `double(forKey:)` — the latter returns 0.0
        // when the key is absent, making it impossible to distinguish "not set" from "set to 0".
        threshold = (defaults.object(forKey: AUBDefaultsKey.threshold) as? Double) ?? 0.80

        theme = AppTheme(
            rawValue: defaults.string(forKey: AUBDefaultsKey.theme) ?? ""
        ) ?? .auto

        openAtLogin    = defaults.bool(forKey: AUBDefaultsKey.openAtLogin)   // false when absent
        hasSeenWelcome = defaults.bool(forKey: AUBDefaultsKey.hasSeenWelcome)

        var map: [ProviderID: Bool] = [:]
        for id in ProviderID.allKnown {
            let key = AUBDefaultsKey.providerEnabled(id)
            if defaults.object(forKey: key) != nil {
                map[id] = defaults.bool(forKey: key)
            }
        }
        providerEnabled = map
    }
}

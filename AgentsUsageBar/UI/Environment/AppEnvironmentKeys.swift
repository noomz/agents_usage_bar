import SwiftUI

/// SwiftUI environment key for the `UserPreferencesStore`.
///
/// Injected at the root of both `MenuBarExtra` and `Settings` scenes via
/// `.environment(\.preferences, dependencies.preferences)` in `AgentsUsageBarApp`.
///
/// Plans 05-03 / 05-04 / 05-06 read this from the environment via
/// `@Environment(\.preferences) private var preferences`.
///
/// B5 invariant: this file does NOT redeclare `ClockKey`, `OpenDashboardURLKey`,
/// or any other existing environment key declared in the sibling files.
// `UserPreferencesStore` is `@MainActor`; SwiftUI's `EnvironmentKey.defaultValue` is also
// accessed on the main thread by SwiftUI's infrastructure. We back the default with a lazily
// created instance that is guarded by `nonisolated(unsafe)` — the instance is only ever
// accessed from the main thread in practice (SwiftUI reads environment values on MainActor).
// Tests always inject an isolated store via `.environment(\.preferences, testStore)` so the
// default is only a fallback for unexpected out-of-test paths.
private struct UserPreferencesStoreKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: UserPreferencesStore = {
        // This closure executes once at program load time on the main thread
        // (SwiftUI evaluates EnvironmentKey defaults from the main actor at startup).
        // The `nonisolated(unsafe)` on the stored value is the Swift 6 mechanism for
        // documenting that the programmer guarantees the access protocol.
        MainActor.assumeIsolated { UserPreferencesStore() }
    }()
}

public extension EnvironmentValues {
    /// The `UserPreferencesStore` instance injected at the app root.
    /// Plans 05-03/04/06 read user-mutable knobs (theme, refreshInterval, etc.) from here.
    var preferences: UserPreferencesStore {
        get { self[UserPreferencesStoreKey.self] }
        set { self[UserPreferencesStoreKey.self] = newValue }
    }
}

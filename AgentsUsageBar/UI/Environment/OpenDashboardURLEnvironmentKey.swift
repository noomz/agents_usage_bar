import AppKit
import SwiftUI

/// SOLE declaration of the `OpenDashboardURLKey` SwiftUI EnvironmentKey
/// + `EnvironmentValues.openDashboardURL` accessor (Plan 03-07 / UI-11 / D-13).
///
/// Mirrors the Phase 1 `ClockKey` precedent (STATE #29) — the environment key
/// keeps `NSWorkspace.shared.open(_:)` OUT of the SwiftUI view body so:
///   1. The view body stays pure (testable without a real `NSWorkspace`).
///   2. Tests can inject a recording closure via
///      `.environment(\.openDashboardURL, recorder)` and assert the closure
///      receives the expected URL when the dashboard button fires.
///   3. Production uses the default closure that calls `NSWorkspace.shared.open(_:)`
///      — the only place in the row UI where AppKit's open-URL API is invoked.
///
/// B5 invariant: this file does NOT redeclare `ClockKey` or extend
/// `EnvironmentValues` with anything other than `openDashboardURL`.
private struct OpenDashboardURLKey: EnvironmentKey {
    static let defaultValue: @MainActor (URL) -> Void = { url in
        _ = NSWorkspace.shared.open(url)
    }
}

public extension EnvironmentValues {
    /// Closure invoked by `ProviderRowView`'s trailing dashboard button to open
    /// the provider's web console (UI-11 / D-13). Defaults to
    /// `NSWorkspace.shared.open(_:)`; tests inject a recording closure.
    var openDashboardURL: @MainActor (URL) -> Void {
        get { self[OpenDashboardURLKey.self] }
        set { self[OpenDashboardURLKey.self] = newValue }
    }
}

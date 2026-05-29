import SwiftUI

/// SOLE declaration of `ClockKey` and `EnvironmentValues.clockService` in the codebase (B5).
///
/// - Plan 01.06 owns this file.
/// - `FooterView` CONSUMES via `@Environment(\.clockService)` — does not redeclare here.
/// - Plan 01.08 INJECTS via `.environment(\.clockService, dependencies.clock)` — does not redeclare here.
///
/// Any future file that needs to read or set the clock service MUST use `@Environment(\.clockService)`
/// and MUST NOT redeclare `struct ClockKey` or extend `EnvironmentValues` with `clockService`.
private struct ClockKey: EnvironmentKey {
    static let defaultValue: any Clock = SystemClock()
}

public extension EnvironmentValues {
    var clockService: any Clock {
        get { self[ClockKey.self] }
        set { self[ClockKey.self] = newValue }
    }
}

import Foundation

/// Protocol seam for the current wall-clock time.
///
/// Production code uses `SystemClock`. Tests inject `VirtualClock` with a pinned or
/// advancing `Date` so time-sensitive logic (day rollover, stale detection) is deterministic.
public protocol Clock: Sendable {
    func now() -> Date
}

/// Production clock — delegates to `Date.now`.
public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { .now }
}

/// Test seam — returns a fixed or closure-driven `Date`.
///
/// Used by Plans 01.04, 01.05, and 01.07 tests to simulate time passage without sleeping.
public struct VirtualClock: Clock, @unchecked Sendable {
    private let _now: () -> Date

    /// Initialise with a closure that returns the current virtual time.
    public init(_ now: @escaping () -> Date) {
        self._now = now
    }

    /// Initialise with a fixed `Date` — always returns the same instant.
    public init(fixed date: Date) {
        self._now = { date }
    }

    public func now() -> Date { _now() }
}

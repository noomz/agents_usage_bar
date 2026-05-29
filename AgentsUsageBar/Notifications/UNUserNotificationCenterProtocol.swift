import UserNotifications

/// Protocol seam wrapping `UNUserNotificationCenter` so that `UNNotificationManager`
/// can be tested without touching the real notification daemon (B3).
///
/// Tests inject a `FakeUNUserNotificationCenter` conforming to this protocol.
/// Production code passes `UNUserNotificationCenter.current()` (the default).
public protocol UNUserNotificationCenterProtocol: Sendable {
    /// Requests authorization to present alerts and play sounds.
    /// Mirrors `UNUserNotificationCenter.requestAuthorization(options:)`.
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool

    /// Schedules a local notification request.
    /// Mirrors `UNUserNotificationCenter.add(_:)`.
    func add(_ request: UNNotificationRequest) async throws
}

/// Default conformance — `UNUserNotificationCenter` satisfies the protocol automatically.
/// Production composition root (Plan 01.08) passes `UNUserNotificationCenter.current()`.
extension UNUserNotificationCenter: UNUserNotificationCenterProtocol {}

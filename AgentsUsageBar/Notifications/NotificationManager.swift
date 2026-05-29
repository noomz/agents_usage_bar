// STUB — overwritten by Plan 01.07
import Foundation

/// Contract for scheduling local notifications.
///
/// Plan 01.07 adds `UNNotificationManager` (backed by `UNUserNotificationCenter`) to this file.
/// The protocol + `NoopNotificationManager` survive Plan 01.07 unchanged.
///
/// This stub exists so `AggregateStore.swift` compiles before Plan 01.07 lands (B2).
public protocol NotificationManager: Sendable {
    /// Schedules or deduplicates local notifications based on the given decisions.
    func schedule(_ decisions: [NotificationDecision]) async
}

/// No-op implementation used in Phase 1 and in tests that don't need notification side-effects.
public struct NoopNotificationManager: NotificationManager {
    public init() {}

    public func schedule(_ decisions: [NotificationDecision]) async {
        // intentional no-op — Plan 01.07 provides the real implementation
    }
}

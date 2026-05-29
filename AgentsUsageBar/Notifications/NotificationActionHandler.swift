import Foundation
import UserNotifications

/// Routes user notification actions (currently only `snooze.today`) into `AggregateStore`.
///
/// ## Wiring (Plan 02.05)
/// `AppDependencies.makeProduction()` constructs the handler and stores it on the
/// `Dependencies` bag. `AgentsUsageBarApp` installs it as the
/// `UNUserNotificationCenter.current().delegate` inside the popover scene's `.task` modifier
/// AFTER `registerCategories(on:)` has been invoked in `init()` (Pitfall 6).
///
/// ## Routing behavior
/// Notification identifiers shipped by `ThresholdEngine` / `UNNotificationManager` follow:
///   - Single: `"<providerID>:<yyyy-MM-dd>:<bandSuffix>"`
///   - Coalesced: `"coalesced:<yyyy-MM-dd>:<bandSuffix>"`
/// The handler parses the leading component:
///   - `"coalesced"` → `store.snoozeAllToday(on:)` (snooze every seeded provider).
///   - anything else → treats as `providerID.rawValue` and calls `store.snoozeToday(...)`.
///
/// Unknown action identifiers and malformed identifiers are silently ignored — the snooze
/// affordance must never crash the app from a Notification Center callback.
@MainActor
public final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {

    private let store: AggregateStore
    private let clock: any Clock
    private let logger = AppLogger.logger(category: "notify")

    public init(store: AggregateStore, clock: any Clock) {
        self.store = store
        self.clock = clock
        super.init()
    }

    // MARK: - UNUserNotificationCenterDelegate

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let identifier = response.notification.request.identifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handle(actionID: actionID, identifier: identifier, now: self.clock.now())
        }
        // Snooze writes are fire-and-forget — the OS does not block UI on this callback.
        // Resolve immediately so Notification Center returns control to the user.
        completionHandler()
    }

    /// Optional Quality-of-life: show banner + sound when the app is foregrounded.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Testable routing helper

    /// Pure routing logic — tests call this directly because `UNNotificationResponse` is not
    /// publicly constructible. The `userNotificationCenter(_:didReceive:...)` delegate method
    /// is a thin wrapper that extracts the action + identifier and delegates here.
    public func handle(actionID: String, identifier: String, now: Date) {
        guard actionID == UNNotificationManager.snoozeActionID else {
            // Unknown actions are no-ops by design.
            return
        }
        guard let firstSeparator = identifier.firstIndex(of: ":") else {
            // Malformed identifier: no `:` separator. Silently ignore (no crash).
            logger.notice("notify action ignored malformed id \(identifier, privacy: .public)")
            return
        }
        let leading = String(identifier[..<firstSeparator])
        if leading == "coalesced" {
            store.snoozeAllToday(on: now)
        } else if !leading.isEmpty {
            store.snoozeToday(providerID: ProviderID(rawValue: leading), on: now)
        }
    }
}

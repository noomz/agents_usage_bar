import Foundation
import UserNotifications
import os

// MARK: - Protocol

/// Contract for scheduling local notifications.
///
/// Plan 01.07 adds `UNNotificationManager` (backed by `UNUserNotificationCenter`) to this file.
/// Plan 02.05 extends the actor with category registration + categoryIdentifier on every
/// request + 3-band coalesced IDs. The protocol surface itself does not change.
public protocol NotificationManager: Sendable {
    /// Schedules or deduplicates local notifications based on the given decisions.
    func schedule(_ decisions: [NotificationDecision]) async
}

// MARK: - UNNotificationManager

/// Production `NotificationManager` backed by `UNUserNotificationCenter`.
///
/// ## Behavior
/// - **Lazy auth (NOTIF-06):** Authorization is requested on the FIRST non-empty `schedule(_:)` call
///   only — never at init or launch.
/// - **Category (Plan 02.05 / Pitfall 6):** Every scheduled request has its
///   `content.categoryIdentifier` set to `usageWarningCategoryID = "usage.warning"`. The
///   matching `UNNotificationCategory` (with the `snooze.today` action) must be registered
///   on the underlying center BEFORE the first `schedule(_:)` call via
///   `registerCategories(on:)` (called from `AgentsUsageBarApp.init()`).
/// - **Coalescing (B3 + NOTIF-07):** When `decisions.count > 1`, fires ONE notification.
///   The coalesced title uses the highest-band integer percent ("N providers crossed 80% / 95% / 100%").
///   Coalesced ID format = `"coalesced:<yyyy-MM-dd>:<bandSuffix>"` where `<bandSuffix>` is
///   `warn80 / crit95 / exceed100` derived from `max(decisions.band)` (Plan 02.05 / NOTIF-03 extension).
/// - **Stable IDs (D-10):** Single-decision uses the engine's pre-computed ID. Coalesced ID
///   derives from `clock.now()` so it remains deterministic in tests (B8).
/// - **Auth denial (D-12):** Silently swallowed — app keeps working; no error propagation.
///
/// ## Security (T-01-07-02 / SEC-02)
/// Only `request.identifier` is logged at `.privacy(.public)`.
/// `title`, `body`, and USD figures are NEVER logged.
public actor UNNotificationManager: NotificationManager {

    // MARK: - Plan 02.05 — Category + Action identifiers (NOTIF-04)

    /// Identifier for the `UNNotificationCategory` shared by every threshold notification
    /// (single + coalesced). Must match the category registered via `registerCategories(on:)`
    /// before the first `schedule(_:)` call — see Pitfall 6.
    public static let usageWarningCategoryID = "usage.warning"

    /// Identifier for the "Snooze for today" action attached to `usage.warning`. Routed
    /// by `NotificationActionHandler.userNotificationCenter(_:didReceive:withCompletionHandler:)`
    /// into `AggregateStore.snoozeToday(providerID:on:)`.
    public static let snoozeActionID = "snooze.today"

    // MARK: - Dependencies

    private let center: any UNUserNotificationCenterProtocol
    private let clock: any Clock          // B8: injected for deterministic coalesced-id day-string
    private let calendar: Calendar
    private let logger = Logger(subsystem: "app.agents-usage-bar", category: "notify")

    // MARK: - Auth state

    private enum AuthState: Sendable {
        case unknown
        case authorized
        case denied
    }

    private var authState: AuthState = .unknown

    // MARK: - Init

    public init(
        center: any UNUserNotificationCenterProtocol = UNUserNotificationCenter.current(),
        clock: any Clock = SystemClock(),       // B8
        calendar: Calendar = .current
    ) {
        self.center = center
        self.clock = clock
        self.calendar = calendar
    }

    // MARK: - Plan 02.05 — Category registration (Pitfall 6)

    /// Registers the `usage.warning` category + `snooze.today` action on `center`.
    ///
    /// MUST be called BEFORE any `schedule(_:)` invocation (Pitfall 6). Production composition
    /// root invokes this in `AgentsUsageBarApp.init()` against `UNUserNotificationCenter.current()`.
    ///
    /// The category registration is performed on the concrete `UNUserNotificationCenter` —
    /// `UNUserNotificationCenterProtocol` does not expose `setNotificationCategories(_:)`
    /// because the test fake never needs to call it. When `center` is the protocol-typed
    /// production instance, we downcast and register; when it's the test fake, this is a no-op.
    public static func registerCategories(on center: any UNUserNotificationCenterProtocol) {
        let snooze = UNNotificationAction(
            identifier: snoozeActionID,
            title: "Snooze for today",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: usageWarningCategoryID,
            actions: [snooze],
            intentIdentifiers: [],
            options: []
        )
        if let concrete = center as? UNUserNotificationCenter {
            concrete.setNotificationCategories([category])
        }
        // Tests using `FakeUNUserNotificationCenter` short-circuit here — the category-on-request
        // contract is verified via `request.content.categoryIdentifier` (test #2/#3).
    }

    // MARK: - NotificationManager

    /// Schedules local notifications for the given decisions.
    public func schedule(_ decisions: [NotificationDecision]) async {
        guard !decisions.isEmpty else { return }
        guard await ensureAuthorized() else { return }

        let request: UNNotificationRequest

        if decisions.count == 1 {
            // Single-decision path: per-provider stable ID + engine-computed title/body (D-13).
            let d = decisions[0]
            let content = UNMutableNotificationContent()
            content.title = d.title
            content.body = d.body
            content.sound = .default
            content.categoryIdentifier = Self.usageWarningCategoryID    // Plan 02.05 / Pitfall 6
            request = UNNotificationRequest(identifier: d.id, content: content, trigger: nil)
        } else {
            // Coalescing path: ONE notification for N providers (B3 + NOTIF-07).
            // Plan 02.05 — highest-band coalesced ID + title percent reflects max band.
            let highestBand = decisions.map(\.band).max() ?? .warning
            let percent = ThresholdEngine.bandPercent(for: highestBand)
            let suffix = ThresholdEngine.bandSuffix(for: highestBand)

            let content = UNMutableNotificationContent()
            content.title = "\(decisions.count) providers crossed \(percent)%"
            content.body = decisions.map(\.displayName).joined(separator: ", ")
            content.sound = .default
            content.categoryIdentifier = Self.usageWarningCategoryID    // Plan 02.05 / Pitfall 6
            // Coalesced stable ID: day-string derived from injected clock (B8) + highest band suffix.
            let dayString = isoDayString(clock.now())
            let coalescedID = "coalesced:\(dayString):\(suffix)"
            request = UNNotificationRequest(identifier: coalescedID, content: content, trigger: nil)
        }

        do {
            try await center.add(request)
            // SEC-02: only the stable identifier is logged; title/body/USD never logged.
            logger.info("scheduled \(request.identifier, privacy: .public)")
        } catch {
            logger.error(
                "notify add failed \(request.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Private helpers

    /// Lazily requests notification authorization on the first call (NOTIF-06).
    ///
    /// - Returns: `true` when the app is authorized; `false` if denied or the request threw.
    private func ensureAuthorized() async -> Bool {
        switch authState {
        case .authorized:
            return true
        case .denied:
            logger.notice("notify auth denied; skipping schedule")
            return false
        case .unknown:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            authState = granted ? .authorized : .denied
            if !granted {
                logger.notice("notify auth denied by user")
            }
            return granted
        }
    }

    /// Derives a `"yyyy-MM-dd"` string in the engine's calendar timezone.
    private func isoDayString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}

// MARK: - NoopNotificationManager

/// No-op implementation used in tests where notification side-effects are irrelevant.
public struct NoopNotificationManager: NotificationManager {
    public init() {}

    public func schedule(_ decisions: [NotificationDecision]) async {
        // intentional no-op
    }
}

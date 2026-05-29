import Foundation
import UserNotifications
import os

// MARK: - Protocol

/// Contract for scheduling local notifications.
///
/// Plan 01.07 adds `UNNotificationManager` (backed by `UNUserNotificationCenter`) to this file.
/// The protocol + `NoopNotificationManager` survive Plan 01.07 unchanged.
public protocol NotificationManager: Sendable {
    /// Schedules or deduplicates local notifications based on the given decisions.
    func schedule(_ decisions: [NotificationDecision]) async
}

// MARK: - UNNotificationManager

/// Phase 1 production `NotificationManager` backed by `UNUserNotificationCenter`.
///
/// ## Behavior
/// - **Lazy auth (NOTIF-06):** Authorization is requested on the FIRST non-empty `schedule(_:)` call
///   only — never at init or launch.
/// - **Coalescing (B3 + NOTIF-07):** When `decisions.count > 1`, fires ONE notification titled
///   `"N providers crossed 80%"` with body listing provider display names in input order.
///   Single-decision path uses the per-provider stable ID from the engine.
/// - **Stable IDs (D-10):** `"<providerID>:<yyyy-MM-dd>:warn80"` (single) or
///   `"coalesced:<yyyy-MM-dd>:warn80"` (multi). OS deduplicates re-fires within the day.
/// - **Auth denial (D-12):** Silently swallowed — app keeps working; no error propagation.
/// - **Clock injection (B8):** `clock: any Clock` parameter ensures the coalesced-id day-string
///   is derived from `clock.now()`, NOT bare `Date()`, making tests deterministic.
///
/// ## Security (T-01-07-02 / SEC-02)
/// Only `request.identifier` is logged at `.privacy(.public)`.
/// `title`, `body`, and USD figures are NEVER logged.
public actor UNNotificationManager: NotificationManager {

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

    // MARK: - NotificationManager

    /// Schedules local notifications for the given decisions.
    ///
    /// - When `decisions` is empty: returns immediately with no auth request (NOTIF-06).
    /// - When `decisions.count == 1`: schedules a per-provider notification using the
    ///   decision's pre-computed stable `id`, `title`, and `body` (D-13).
    /// - When `decisions.count > 1`: coalesces into ONE notification titled
    ///   `"N providers crossed 80%"` with body = comma-joined `displayName` values (B3 + NOTIF-07).
    ///   Coalesced ID = `"coalesced:<yyyy-MM-dd>:warn80"` using `clock.now()` (B8).
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
            request = UNNotificationRequest(identifier: d.id, content: content, trigger: nil)
        } else {
            // Coalescing path: ONE notification for N providers (B3 + NOTIF-07).
            let content = UNMutableNotificationContent()
            content.title = "\(decisions.count) providers crossed 80%"
            content.body = decisions.map(\.displayName).joined(separator: ", ")
            content.sound = .default
            // Coalesced stable ID: day-string derived from injected clock (B8).
            let dayString = isoDayString(clock.now())
            let coalescedID = "coalesced:\(dayString):warn80"
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
    ///   Auth denial is silently swallowed (D-12) — no error propagates to callers.
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
    ///
    /// Uses `DateFormatter` with `calendar = self.calendar` and
    /// `timeZone = calendar.timeZone` — avoids the Gregorian-hardcode pitfall (Pitfall 4).
    private func isoDayString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}

// MARK: - NoopNotificationManager

/// No-op implementation used in tests and Phase 1 composition root until Plan 01.08 wires in
/// `UNNotificationManager`.
public struct NoopNotificationManager: NotificationManager {
    public init() {}

    public func schedule(_ decisions: [NotificationDecision]) async {
        // intentional no-op
    }
}

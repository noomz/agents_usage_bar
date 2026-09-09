import Foundation

/// A pure value describing a notification that the threshold engine has decided to fire.
///
/// `NotificationManager` (Plan 01.07) converts `NotificationDecision` values into
/// `UNNotificationRequest` instances. Using a value type here keeps `ThresholdEngine`
/// pure and testable without `UNUserNotificationCenter` involvement.
///
/// D-10: The `id` field is stable across polls so the OS deduplicates re-fires when
/// the quota stays above the threshold across multiple refresh cycles.
public struct NotificationDecision: Sendable, Equatable {

    /// Stable unique identifier for this notification.
    /// Single-provider format: `"<providerID>:<yyyy-MM-dd>:warn80"`
    /// Coalesced format (D-10b): `"coalesced:<yyyy-MM-dd>:warn80"`
    public let id: String

    /// Notification title shown in the system notification banner.
    /// Example: `"OpenRouter at 82%"` (D-13).
    public let title: String

    /// Notification body text.
    /// Example: `"$8.20 of $10.00 used today."` (D-13).
    public let body: String

    /// The provider this decision originated from (used for per-provider action routing).
    public let providerID: ProviderID

    /// Human-readable provider display name for coalesced notification bodies (B3).
    /// Example: `"OpenRouter"`, `"Claude"`, `"Codex"`.
    public let displayName: String

    /// The threshold band that triggered this decision.
    /// Always `.warning` in Phase 1 (D-11). Pace warnings also use `.warning`
    /// so they share the snooze category; they are identified by `windowName`
    /// and an id suffix of `:pace:`.
    public let band: ThresholdBand

    /// Quota-window name for pace warnings (e.g. `"5h"`, `"primary"`). `nil` for
    /// threshold-band decisions.
    public let windowName: String?

    public init(
        id: String,
        title: String,
        body: String,
        providerID: ProviderID,
        displayName: String,
        band: ThresholdBand,
        windowName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.providerID = providerID
        self.displayName = displayName
        self.band = band
        self.windowName = windowName
    }
}

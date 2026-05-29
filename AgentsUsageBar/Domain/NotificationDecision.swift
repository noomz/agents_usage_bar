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

    public init(id: String, title: String, body: String, providerID: ProviderID) {
        self.id = id
        self.title = title
        self.body = body
        self.providerID = providerID
    }
}

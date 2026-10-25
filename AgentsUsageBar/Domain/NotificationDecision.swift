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
    /// Always `.warning` in Phase 1 (D-11). Pace and reset-back notifications
    /// also use `.warning` so they share the snooze category; they are identified
    /// by `windowName` and an id suffix of `:pace:` or `:reset:`.
    public let band: ThresholdBand

    /// Quota-window name for pace and reset-back notifications (e.g. `"5h"`,
    /// `"primary"`). `nil` for threshold-band decisions.
    public let windowName: String?

    /// False for a budget notification, which has no snooze action (SPEC V66).
    public let snoozable: Bool

    public init(
        id: String,
        title: String,
        body: String,
        providerID: ProviderID,
        displayName: String,
        band: ThresholdBand,
        windowName: String? = nil,
        snoozable: Bool = true
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.providerID = providerID
        self.displayName = displayName
        self.band = band
        self.windowName = windowName
        self.snoozable = snoozable
    }
}

/// One crossing an engine detected on this poll: a quota band, a pace warning, or a
/// window reset (SPEC V34). Detection ignores snooze and the enabled toggles; the
/// dispatch gate sets `notified`, and the caller advances band and fired state for every
/// crossing so turning notifications on later the same day does not re-fire it.
public struct QuotaCrossing: Sendable, Equatable {
    public let providerID: ProviderID
    public let kind: UsageEventKind
    /// Quota-window name for pace and reset; nil for a provider-level band.
    public let window: String?
    /// Band: the provider's quota fraction. Pace: the window's utilization. Reset: the
    /// window's utilization before it reset.
    public let fraction: Double
    public let notified: Bool
    /// Entry for today's fired set: the window name for pace, window plus old
    /// `resetsAt` for reset (`ResetEngine.fireKey`), nil for a band.
    public let stateKey: String?

    public init(
        providerID: ProviderID,
        kind: UsageEventKind,
        window: String? = nil,
        fraction: Double,
        notified: Bool,
        stateKey: String? = nil
    ) {
        self.providerID = providerID
        self.kind = kind
        self.window = window
        self.fraction = fraction
        self.notified = notified
        self.stateKey = stateKey
    }
}

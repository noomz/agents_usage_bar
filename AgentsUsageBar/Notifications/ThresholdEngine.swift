import Foundation

/// Pure value-type engine that computes per-provider notification decisions.
///
/// ## Design constraints
/// - **Pure:** no I/O, no `UNUserNotificationCenter`, no `os.Logger`, no `FileManager`.
///   Every method is deterministic given its inputs — fully unit-testable in < 1 ms.
/// - **FSM modeled:** `ThresholdBand` covers all four states (`normal/warning/critical/exceeded`).
/// - **Phase 1 gate (D-11):** only `.warning` emits a `NotificationDecision`.
///   `.critical` and `.exceeded` are computed via `currentBand(for:)` but produce no
///   decision until Phase 2 fills in their emission paths.
/// - **No-limit gate (D-14):** `quota == nil` → returns no decision for that provider.
/// - **Snooze gate:** `snoozedUntil[providerID] > now` → decision suppressed.
/// - **Stable IDs (D-10):** `"<providerID>:<yyyy-MM-dd>:warn80"` — OS deduplicates
///   re-fires across polls within the same calendar day.
public struct ThresholdEngine: Sendable {

    /// Fraction at which the Warning band begins (default 0.80 = 80%).
    public let warningFraction: Double

    /// Calendar used for ISO day-string derivation.
    /// Defaults to `Calendar.current` (local timezone) per Pitfall 4.
    private let calendar: Calendar

    public init(warningFraction: Double = 0.80, calendar: Calendar = .current) {
        self.warningFraction = warningFraction
        self.calendar = calendar
    }

    // MARK: - Public API

    /// Returns a `NotificationDecision` for each snapshot whose quota fraction falls
    /// in the `.warning` band and is not snoozed.
    ///
    /// The returned list may have 0, 1, or N elements — `UNNotificationManager` coalesces
    /// it when `count > 1` (B3 + NOTIF-07).
    ///
    /// - Parameters:
    ///   - snapshots: Provider usage snapshots from the current poll tick.
    ///   - now: Current wall-clock time. Used for snooze comparison and day-string generation.
    ///   - snoozedUntil: Per-provider snooze expiry map (D-10). Phase 1 always passes `[:]`.
    /// - Returns: One decision per qualifying provider, in input order.
    public func decisions(
        for snapshots: [UsageSnapshot],
        now: Date,
        snoozedUntil: [ProviderID: Date]
    ) -> [NotificationDecision] {
        snapshots.compactMap { snap -> NotificationDecision? in
            // D-14: no-limit accounts have nil quota — skip entirely.
            guard let quota = snap.quota else { return nil }

            // FSM gate: only .warning emits in Phase 1 (D-11).
            let band = currentBand(for: quota.fraction)
            guard band == .warning else { return nil }

            // Snooze gate: suppress if provider is snoozed past `now`.
            if let snoozeExpiry = snoozedUntil[snap.providerID], snoozeExpiry > now {
                return nil
            }

            let displayName = snap.providerID.displayHint
            let dayString = isoDayString(now)
            let id = "\(snap.providerID.rawValue):\(dayString):warn80"
            let percent = Int((quota.fraction * 100).rounded(.towardZero))
            let title = "\(displayName) at \(percent)%"
            let body = formatBody(used: quota.used, limit: quota.limit)

            return NotificationDecision(
                id: id,
                title: title,
                body: body,
                providerID: snap.providerID,
                displayName: displayName,
                band: .warning
            )
        }
    }

    /// Maps a quota fraction to the corresponding `ThresholdBand`.
    ///
    /// Breakpoints (D-11):
    /// - `< 0.80`   → `.normal`
    /// - `0.80..<0.95` → `.warning`
    /// - `0.95..<1.00` → `.critical`
    /// - `>= 1.00`  → `.exceeded`
    public func currentBand(for fraction: Double) -> ThresholdBand {
        if fraction >= 1.00 { return .exceeded }
        if fraction >= 0.95 { return .critical }
        if fraction >= 0.80 { return .warning }
        return .normal
    }

    // MARK: - Private helpers

    /// Formats the notification body as `"$X.XX of $Y.YY used today."` (D-13).
    ///
    /// Uses `NumberFormatter` with `.currency` style and `currencyCode = "USD"`.
    private func formatBody(used: Double, limit: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = "USD"
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        let usedStr  = fmt.string(from: NSNumber(value: used))  ?? "$\(used)"
        let limitStr = fmt.string(from: NSNumber(value: limit)) ?? "$\(limit)"
        return "\(usedStr) of \(limitStr) used today."
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

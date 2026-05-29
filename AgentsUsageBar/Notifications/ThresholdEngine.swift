import Foundation

/// Pure value-type engine that computes per-provider notification decisions.
///
/// ## Design constraints
/// - **Pure:** no I/O, no `UNUserNotificationCenter`, no `os.Logger`, no `FileManager`.
///   Every method is deterministic given its inputs — fully unit-testable in < 1 ms.
/// - **FSM modeled:** `ThresholdBand` covers all four states (`normal/warning/critical/exceeded`).
/// - **Phase 2 emission (NOTIF-01 + NOTIF-02 + NOTIF-03):** the FSM-aware overload
///   `decisions(for:now:snoozedUntilDay:lastBands:)` emits ONE decision per provider
///   whose `newBand > oldBand` and `newBand != .normal`, with stable IDs ending in
///   `:warn80`, `:crit95`, or `:exceed100`.
/// - **Phase 1 back-compat:** `decisions(for:now:snoozedUntil:)` is preserved as a thin
///   wrapper that internally delegates to the new overload with `lastBands = [:]` and a
///   synthesized `snoozedUntilDay`. Phase 1 NotificationManagerTests + ThresholdEngineTests
///   continue to pass with warn80-only emission (D-11 preserved at the back-compat surface).
/// - **No-limit gate (D-14):** `quota == nil` → returns no decision for that provider.
/// - **Snooze gate (NOTIF-05):** `snoozedUntilDay[providerID] == today` → suppresses ALL
///   subsequent bands for the provider until local-midnight rollover (default decision #2).
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

    // MARK: - Phase 1 back-compat surface (D-11 warn80-only emission)

    /// Phase 1 back-compat overload — emits only `.warning` decisions.
    ///
    /// Internally delegates to the FSM-aware overload with `lastBands = [:]` and a
    /// `snoozedUntilDay` map synthesized from the absolute-`Date` snooze expiries.
    /// Callers wanting all three bands must use `decisions(for:now:snoozedUntilDay:lastBands:)`
    /// (Plan 02.05 / NOTIF-01).
    public func decisions(
        for snapshots: [UsageSnapshot],
        now: Date,
        snoozedUntil: [ProviderID: Date]
    ) -> [NotificationDecision] {
        let today = TodayHelper.formatYYYYMMDD(now, calendar: calendar)
        let snoozedUntilDay: [ProviderID: String] = snoozedUntil.compactMapValues { expiry in
            expiry > now ? today : nil
        }
        let fsmDecisions = decisions(
            for: snapshots,
            now: now,
            snoozedUntilDay: snoozedUntilDay,
            lastBands: [:]
        )
        // Phase 1 emission policy (D-11): warn80-only.
        return fsmDecisions.filter { $0.band == .warning }
    }

    // MARK: - Phase 2 FSM-aware surface (NOTIF-01..05)

    /// Returns one `NotificationDecision` per provider whose threshold band has
    /// transitioned UPWARD since the last poll, gated by per-provider snooze.
    ///
    /// Algorithm (NOTIF-02 + NOTIF-05 + default decision #2):
    /// 1. `currentBand(for: quota.fraction)` → `newBand`.
    /// 2. `lastBands[providerID] ?? .normal` → `oldBand`.
    /// 3. Emit only when `newBand > oldBand` AND `newBand != .normal`.
    /// 4. Suppress entirely when `snoozedUntilDay[providerID] == today` (ALL bands).
    ///
    /// Stable IDs (NOTIF-03):
    /// - `.warning`  → `"<providerID>:<yyyy-MM-dd>:warn80"`
    /// - `.critical` → `"<providerID>:<yyyy-MM-dd>:crit95"`
    /// - `.exceeded` → `"<providerID>:<yyyy-MM-dd>:exceed100"`
    public func decisions(
        for snapshots: [UsageSnapshot],
        now: Date,
        snoozedUntilDay: [ProviderID: String],
        lastBands: [ProviderID: ThresholdBand]
    ) -> [NotificationDecision] {
        let today = TodayHelper.formatYYYYMMDD(now, calendar: calendar)

        return snapshots.compactMap { snap -> NotificationDecision? in
            // D-14: no-limit accounts have nil quota — skip entirely.
            guard let quota = snap.quota else { return nil }

            let newBand = currentBand(for: quota.fraction)
            let oldBand = lastBands[snap.providerID] ?? .normal

            // NOTIF-02: only on UPWARD transition.
            guard newBand > oldBand else { return nil }
            // `.normal` is never a target (`newBand > oldBand` and `oldBand >= .normal`
            // imply `newBand > .normal`), but the explicit gate keeps the contract obvious.
            guard newBand != .normal else { return nil }

            // NOTIF-05 + default decision #2: snooze suppresses ALL bands for this provider.
            if snoozedUntilDay[snap.providerID] == today { return nil }

            return makeDecision(snap: snap, newBand: newBand, today: today, quota: quota)
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
        if fraction >= warningFraction { return .warning }
        return .normal
    }

    // MARK: - Private helpers

    /// Builds a `NotificationDecision` for `(snap, newBand)`. Stable IDs and titles encode
    /// the band suffix and integer percent threshold per NOTIF-03.
    private func makeDecision(
        snap: UsageSnapshot,
        newBand: ThresholdBand,
        today: String,
        quota: Quota
    ) -> NotificationDecision {
        let displayName = snap.providerID.displayHint
        let suffix = bandSuffix(for: newBand)
        let id = "\(snap.providerID.rawValue):\(today):\(suffix)"
        let percent = Int((quota.fraction * 100).rounded(.towardZero))
        let title = "\(displayName) at \(percent)%"
        let body = formatBody(used: quota.used, limit: quota.limit)
        return NotificationDecision(
            id: id,
            title: title,
            body: body,
            providerID: snap.providerID,
            displayName: displayName,
            band: newBand
        )
    }

    /// Stable ID suffix per band — NOTIF-03 contract. Coalesced IDs reuse the same suffix
    /// derived from the maximum band in a multi-decision batch.
    public static func bandSuffix(for band: ThresholdBand) -> String {
        switch band {
        case .normal:   return "normal"   // unreachable in emission path but exhaustive
        case .warning:  return "warn80"
        case .critical: return "crit95"
        case .exceeded: return "exceed100"
        }
    }

    /// Instance accessor so existing call sites stay terse.
    func bandSuffix(for band: ThresholdBand) -> String {
        Self.bandSuffix(for: band)
    }

    /// Integer percent threshold for a band — used in coalesced titles ("3 providers crossed 80%").
    public static func bandPercent(for band: ThresholdBand) -> Int {
        switch band {
        case .normal:   return 0
        case .warning:  return 80
        case .critical: return 95
        case .exceeded: return 100
        }
    }

    /// Formats the notification body as `"$X.XX of $Y.YY used today."` (D-13).
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
}

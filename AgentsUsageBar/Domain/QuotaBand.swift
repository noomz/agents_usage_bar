import Foundation

/// UI-03 remaining-fraction band. Authoritative color/bar mapping for both
/// `QuotaBar` (SwiftUI) and the `aub` ASCII renderer.
///
/// Thresholds (REQUIREMENTS.md UI-02 / UI-03):
///   - `nil` remaining            → `.none`     (no-limit account)
///   - remaining `< 0.20`         → `.critical`
///   - `0.20 ≤ remaining < 0.50`  → `.warning`
///   - remaining `≥ 0.50`         → `.healthy`
///
/// Callers pass the **remaining** fraction (`1 - Quota.fraction`), not consumed.
public enum QuotaBand: Sendable, Equatable {
    case none
    case critical
    case warning
    case healthy

    /// Maps a remaining-quota fraction onto a band. `nil` is the no-limit account.
    public static func fromRemainingFraction(_ fraction: Double?) -> QuotaBand {
        guard let f = fraction else { return .none }
        let clamped = min(max(f, 0), 1)
        if clamped < 0.20 { return .critical }
        if clamped < 0.50 { return .warning }
        return .healthy
    }
}

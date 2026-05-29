import Foundation

/// FSM enum modeling quota utilization severity.
///
/// D-11: Phase 1 emits only `.warning` (80%). The `.critical` (95%) and `.exceeded` (100%)
/// cases exist so Phase 2 can fill them in without a rewrite. The `ThresholdEngine` in
/// Plan 01.07 uses `ThresholdState.from(fraction:)` to derive a decision per provider.
///
/// Phase 1 emission policy: only `.warning` fires a `UNUserNotificationCenter` call.
/// `.critical` and `.exceeded` paths are present but produce no notification until Phase 2.
///
/// See also `ThresholdBand` (used by Plan 01.07 engine tests) defined in Plan 01.07.
public enum ThresholdState: Sendable, Equatable, Codable {
    /// Quota fraction < 80%.
    case normal

    /// Quota fraction >= 80% and < 95%. Phase 1 fires the warning notification at this level.
    case warning

    /// Quota fraction >= 95% and < 100%. Phase 2 fires critical notification.
    case critical

    /// Quota fraction >= 100%. Phase 2 fires exceeded notification.
    case exceeded

    /// Pure function: derives the appropriate `ThresholdState` for a given quota fraction.
    ///
    /// Breakpoints (D-11, D-13):
    /// - `< 0.80`  → `.normal`
    /// - `>= 0.80` → `.warning`
    /// - `>= 0.95` → `.critical`
    /// - `>= 1.00` → `.exceeded`
    public static func from(fraction: Double) -> ThresholdState {
        if fraction >= 1.0 { return .exceeded }
        if fraction >= 0.95 { return .critical }
        if fraction >= 0.80 { return .warning }
        return .normal
    }
}

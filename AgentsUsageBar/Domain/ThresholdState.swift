import Foundation

/// Four-state FSM enum used by `ThresholdEngine` (Plan 01.07) to model quota severity.
///
/// Phase 1 emits decisions ONLY for `.warning` (D-11). The `.critical` and `.exceeded`
/// cases are modeled so Phase 2 can fill in emission without a structural rewrite.
///
/// - Note: `ThresholdBand` serves the same semantic role as `ThresholdState` but is the
///   type returned by `ThresholdEngine.currentBand(for:)`. Both live here to avoid a
///   separate file, since they share the same breakpoint semantics.
public enum ThresholdBand: Sendable, Equatable, CaseIterable, Codable {
    /// Quota fraction < 80%.
    case normal
    /// Quota fraction >= 80% and < 95%.
    case warning
    /// Quota fraction >= 95% and < 100%.
    case critical
    /// Quota fraction >= 100%.
    case exceeded
}

/// Comparable conformance (Plan 02.05 / NOTIF-01) — orders by severity rank so the
/// Phase 2 FSM can detect UPWARD-only transitions via `newBand > oldBand` (NOTIF-02).
///
/// Rank: normal(0) < warning(1) < critical(2) < exceeded(3). See RESEARCH §E.1.
extension ThresholdBand: Comparable {
    private var rank: Int {
        switch self {
        case .normal:   return 0
        case .warning:  return 1
        case .critical: return 2
        case .exceeded: return 3
        }
    }

    public static func < (lhs: ThresholdBand, rhs: ThresholdBand) -> Bool {
        lhs.rank < rhs.rank
    }
}

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

import Foundation

/// User-configurable polling cadence.
///
/// D-15: The valid set of intervals for Phase 1.
/// `ConfigStore` (Plan 01.03) reads the TOML string and calls `RefreshInterval.parse(_:)`
/// to convert it. Unknown/invalid strings fall back to `.default` (D-18 fail-soft).
///
/// POLL-02: The default refresh interval is 5 minutes.
public enum RefreshInterval: Sendable, Equatable, Codable, CaseIterable {
    case manual
    case m1
    case m2
    case m5
    case m15
    case m30

    /// The polling cadence in seconds, or `nil` for `.manual` (user-triggered only).
    public var seconds: TimeInterval? {
        switch self {
        case .manual: return nil
        case .m1:     return 60
        case .m2:     return 120
        case .m5:     return 300
        case .m15:    return 900
        case .m30:    return 1800
        }
    }

    /// Default polling interval (POLL-02).
    public static let `default`: Self = .m5

    /// Converts a TOML string value to a `RefreshInterval`.
    ///
    /// Accepted values (D-15): `"manual"`, `"1m"`, `"2m"`, `"5m"`, `"15m"`, `"30m"`.
    /// Returns `nil` for any other input — the caller (`ConfigStore`) applies the default.
    public static func parse(_ tomlValue: String) -> RefreshInterval? {
        switch tomlValue {
        case "manual": return .manual
        case "1m":     return .m1
        case "2m":     return .m2
        case "5m":     return .m5
        case "15m":    return .m15
        case "30m":    return .m30
        default:       return nil
        }
    }
}

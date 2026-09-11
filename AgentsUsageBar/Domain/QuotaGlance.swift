import Foundation

/// Provider-neutral presentation selection for canonical Claude 5-hour and 7-day windows.
/// UI and CLI consume this value so they agree on displayed values, active constraint, and reset.
public struct QuotaGlance: Sendable, Equatable {
    public enum Period: String, Sendable, Equatable {
        case fiveHours = "5h"
        case sevenDays = "7d"
    }

    public struct Window: Sendable, Equatable {
        public let period: Period
        public let utilization: Double?
        public let resetsAt: Date?
        public let accountName: String?

        public init(period: Period, utilization: Double?, resetsAt: Date?, accountName: String? = nil) {
            self.period = period
            self.utilization = utilization
            self.resetsAt = resetsAt
            self.accountName = accountName
        }
    }

    public let fiveHours: Window?
    public let sevenDays: Window?
    public let active: Window?

    public init(windows: [Window]) {
        fiveHours = Self.select(.fiveHours, from: windows)
        sevenDays = Self.select(.sevenDays, from: windows)
        active = Self.activeConstraint(fiveHours: fiveHours, sevenDays: sevenDays)
    }

    /// Canonical Claude primary windows only. Secondary 7d model windows excluded.
    public init(quotaWindows: [QuotaWindow], accountName: String? = nil) {
        self.init(windows: quotaWindows.compactMap { window in
            let period: Period?
            if window.isFiveHour {
                period = .fiveHours
            } else if window.isSevenDay {
                period = .sevenDays
            } else {
                period = nil
            }
            return period.map { Window(period: $0, utilization: window.utilization, resetsAt: window.resetsAt, accountName: accountName) }
        })
    }

    public var hasAnyWindow: Bool { fiveHours != nil || sevenDays != nil }
    public var hasBothWindows: Bool { fiveHours != nil && sevenDays != nil }

    /// Rounded text intentionally stays separate from raw active selection.
    public func percent(for period: Period) -> String {
        let utilization = window(for: period)?.utilization
        return utilization.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    public func window(for period: Period) -> Window? {
        switch period {
        case .fiveHours: fiveHours
        case .sevenDays: sevenDays
        }
    }

    private static func select(_ period: Period, from windows: [Window]) -> Window? {
        windows
            .filter { $0.period == period }
            .max { lhs, rhs in
                let left = lhs.utilization ?? -1
                let right = rhs.utilization ?? -1
                if left != right { return left < right }
                return (lhs.resetsAt ?? .distantFuture) > (rhs.resetsAt ?? .distantFuture)
            }
    }

    private static func activeConstraint(fiveHours: Window?, sevenDays: Window?) -> Window? {
        switch (fiveHours?.utilization, sevenDays?.utilization) {
        case let (five?, seven?):
            if five != seven { return five > seven ? fiveHours : sevenDays }
            let fiveReset = fiveHours?.resetsAt ?? .distantFuture
            let sevenReset = sevenDays?.resetsAt ?? .distantFuture
            return fiveReset <= sevenReset ? fiveHours : sevenDays
        case (.some, nil): return fiveHours
        case (nil, .some): return sevenDays
        default: return nil
        }
    }
}

public extension QuotaWindow {
    /// Canonical weekly window. Excludes `7d-sonnet` and `7d-opus` secondary windows.
    var isSevenDay: Bool {
        name == "7d" || name.hasSuffix(" 7d")
    }
}

public extension UsageSnapshot {
    /// Aggregate Claude glance. Multi-account sources contribute one candidate per primary period.
    var quotaGlance: QuotaGlance {
        if let accounts, !accounts.isEmpty {
            return QuotaGlance(windows: accounts.flatMap { account in
                (account.quotaWindows ?? []).compactMap { window in
                    if window.isFiveHour {
                        return QuotaGlance.Window(period: .fiveHours, utilization: window.utilization, resetsAt: window.resetsAt, accountName: account.name)
                    }
                    if window.isSevenDay {
                        return QuotaGlance.Window(period: .sevenDays, utilization: window.utilization, resetsAt: window.resetsAt, accountName: account.name)
                    }
                    return nil
                }
            })
        }
        return QuotaGlance(quotaWindows: quotaWindows ?? [])
    }
}

public extension UsageSnapshot.AccountUsage {
    var quotaGlance: QuotaGlance {
        QuotaGlance(quotaWindows: quotaWindows ?? [], accountName: name)
    }
}

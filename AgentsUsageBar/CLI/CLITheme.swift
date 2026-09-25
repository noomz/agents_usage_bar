import Foundation

/// Which `aub` text view a theme renders.
public enum CLIView: Sendable, Equatable {
    case usage
    case quota
}

/// Built-in layout for `aub` terminal output. Static switch; no runtime loading.
public enum CLITheme: String, CaseIterable, Sendable {
    case compact
    case classic

    public func render(_ report: UsageReport, view: CLIView, color: Bool) -> String {
        switch self {
        case .compact:
            return CompactTextRenderer.render(report, view: view, color: color, width: CompactTextRenderer.terminalWidth())
        case .classic:
            switch view {
            case .usage: return UsageTextRenderer.renderUsage(report, color: color)
            case .quota: return UsageTextRenderer.renderQuota(report, color: color)
            }
        }
    }
}

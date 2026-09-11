import SwiftUI

/// Compact dual-window Claude quota presentation. Other providers keep `QuotaBar`.
struct ClaudeQuotaGlanceView: View {
    let glance: QuotaGlance
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if glance.hasBothWindows {
                compositeBar
            } else if let window = glance.fiveHours ?? glance.sevenDays {
                QuotaBar(quota: window.utilization.map { Quota(used: $0, limit: 1, remaining: max(0, 1 - $0)) })
            } else {
                QuotaBar(quota: nil)
            }

            HStack(spacing: 4) {
                periodLabel(.fiveHours)
                Text("·").foregroundStyle(.secondary)
                periodLabel(.sevenDays)
                Spacer(minLength: 0)
                if let active = glance.active, let reset = active.resetsAt {
                    Text(resetCaption(for: active, reset: reset))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private var compositeBar: some View {
        GeometryReader { proxy in
            VStack(spacing: 1) {
                lane(for: .fiveHours, width: proxy.size.width)
                lane(for: .sevenDays, width: proxy.size.width)
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func lane(for period: QuotaGlance.Period, width: CGFloat) -> some View {
        let utilization = glance.window(for: period)?.utilization ?? 0
        let color = QuotaBar.color(forFraction: 1 - utilization)
        return ZStack(alignment: .leading) {
            Rectangle().fill(Color.secondary.opacity(0.15))
            Rectangle().fill(color).frame(width: width * utilization)
        }
    }

    private func periodLabel(_ period: QuotaGlance.Period) -> some View {
        let emphasized = isEmphasized(period)
        return Text("\(period.rawValue) \(glance.percent(for: period))")
            .fontWeight(emphasized ? .semibold : .regular)
            .foregroundStyle(emphasized ? .primary : .secondary)
    }

    /// Exact raw selection controls reset; rounded tie intentionally has no bold label.
    private func isEmphasized(_ period: QuotaGlance.Period) -> Bool {
        guard let active = glance.active,
              glance.hasBothWindows,
              glance.percent(for: .fiveHours) != glance.percent(for: .sevenDays)
        else { return false }
        return active.period == period
    }

    private func resetCaption(for active: QuotaGlance.Window, reset: Date) -> String {
        let tied = glance.fiveHours?.utilization == glance.sevenDays?.utilization
        return "\(tied ? "Next reset" : "Resets") \(ResetCountdown.phrase(until: reset, now: now))"
    }

    private var accessibilityLabel: String { "Claude quota" }

    private var accessibilityValue: String {
        let active = glance.active
        let values = "5h \(glance.percent(for: .fiveHours)), 7d \(glance.percent(for: .sevenDays))"
        guard let active else { return "\(values), unavailable" }
        var description = "\(values), active constraint \(active.accountName.map { "\($0) " } ?? "")\(active.period.rawValue)"
        if let reset = active.resetsAt {
            description += ", \(resetCaption(for: active, reset: reset))"
        }
        return description
    }
}

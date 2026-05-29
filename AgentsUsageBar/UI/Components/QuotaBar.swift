import SwiftUI

/// UI-03 reconciliation (Plan 02.07): The thresholds below ARE the ClaudeBar
/// convention as defined by REQUIREMENTS.md UI-03. Phase 1 D-30 / B4 already
/// implemented them; Plan 02.07 verifies + locks the convention against drift.
/// Any future alteration to these breakpoints requires a coordinated UI-03 RFC.
///
/// Color-coded quota progress bar per UI-02 / UI-03 (REQUIREMENTS.md authoritative, B4).
///
/// Color mapping:
///   - `quota == nil`    → gray bar + "no limit" caption (D-14, ROUTER-03)
///   - fraction < 0.20   → red   (< 20% remaining — critical)
///   - 0.20 ≤ fraction < 0.50 → yellow (20–50% remaining — warning)
///   - fraction ≥ 0.50   → green (≥ 50% remaining — healthy)
///
/// The pure color function `color(forFraction:)` is exposed as `internal static` so
/// `QuotaBarTests` can verify all 8 B4 boundary cases without needing a snapshot framework.
public struct QuotaBar: View {
    public let quota: Quota?

    public init(quota: Quota?) {
        self.quota = quota
    }

    // MARK: - View body

    public var body: some View {
        if let quota {
            let fraction = min(max(quota.fraction, 0), 1)
            let color = Self.color(forFraction: fraction)
            VStack(alignment: .leading, spacing: 2) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                        Rectangle()
                            .fill(color)
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 6)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        } else {
            // nil quota → no-limit account (D-14)
            HStack(spacing: 4) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                        Rectangle()
                            .fill(Color.gray)
                            .frame(width: proxy.size.width)
                    }
                }
                .frame(height: 6)
                .clipShape(RoundedRectangle(cornerRadius: 3))

                Text("no limit")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Color function (B4 test seam)

    /// Returns the bar color for the given `fraction`, or `.gray` for nil (no-limit account).
    ///
    /// This function is the AUTHORITATIVE implementation of the UI-02 color mapping (B4).
    /// Tests call this directly via `QuotaBar.color(forFraction:)`.
    ///
    /// Thresholds (REQUIREMENTS.md UI-02):
    ///   - nil           → Color.gray  ("no limit")
    ///   - clamped < 0.20  → Color.red
    ///   - clamped < 0.50  → Color.yellow
    ///   - clamped ≥ 0.50  → Color.green
    internal static func color(forFraction fraction: Double?) -> Color {
        guard let f = fraction else { return .gray }
        let clamped = min(max(f, 0), 1)
        if clamped < 0.20 { return .red }
        if clamped < 0.50 { return .yellow }
        return .green  // fraction >= 0.50 (UI-02 authoritative, B4)
    }
}

// MARK: - Previews

#Preview("QuotaBar — green (healthy, 75%)") {
    QuotaBar(quota: Quota(used: 7.5, limit: 10.0, remaining: 2.5))
        .frame(width: 200)
        .padding()
}

#Preview("QuotaBar — yellow (warning, 35%)") {
    QuotaBar(quota: Quota(used: 3.5, limit: 10.0, remaining: 6.5))
        .frame(width: 200)
        .padding()
}

#Preview("QuotaBar — red (critical, 10%)") {
    QuotaBar(quota: Quota(used: 9.0, limit: 10.0, remaining: 1.0))
        .frame(width: 200)
        .padding()
}

#Preview("QuotaBar — gray (no limit, nil quota)") {
    QuotaBar(quota: nil)
        .frame(width: 200)
        .padding()
}

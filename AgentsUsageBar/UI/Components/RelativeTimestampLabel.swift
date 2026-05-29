import SwiftUI

/// A `TimelineView`-driven label that shows "Updated Xs ago" and ticks every second
/// while the popover is open (Phase Success Criterion #3).
///
/// - Renders "Never updated" when `date == nil` (cold-launch / unauthenticated state, D-03).
/// - Uses `relativeString(from:to:)` which is exposed as `internal static` for unit testing (W2).
///
/// Phase 1 trade-off (W2 comment): Very long elapsed periods (>24h) render as "Xd ago" rather
/// than switching to an absolute date string. This keeps the label compact and avoids locale/timezone
/// complexity. Revisit in Phase 2 if user feedback demands absolute timestamps.
///
/// Plan 02.07 (UI-08): the `isStale` flag swaps the foreground style from
/// `.secondary` to `.tertiary` when the row's data is older than 2× the current
/// refresh interval. The text content is unchanged ("Updated 7m ago") — only
/// the colour intensity differs so the user notices the data is stale.
public struct RelativeTimestampLabel: View {
    public let date: Date?
    public let prefix: String
    public let isStale: Bool

    /// Plan 02.07 — additive overload accepting `isStale` from
    /// `AggregateStore.isStale(_:now:)`. The default `false` preserves Phase 1
    /// call-site compatibility.
    public init(date: Date?, prefix: String = "Updated", isStale: Bool = false) {
        self.date = date
        self.prefix = prefix
        self.isStale = isStale
    }

    // MARK: - View body

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date
            if let date {
                Text("\(prefix) \(Self.relativeString(from: date, to: now)) ago")
                    .font(.caption2)
                    .foregroundStyle(isStale ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                                             : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            } else {
                Text("Never updated")
                    .font(.caption2)
                    .foregroundStyle(isStale ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                                             : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
        }
    }

    // MARK: - Pure helper (W2 test seam)

    /// Returns a compact human-readable elapsed-time string between `start` and `end`.
    ///
    /// Boundaries:
    ///   - 0–59s  → "Xs"
    ///   - 60–3599s → "Xm"
    ///   - 3600–86399s → "Xh"
    ///   - ≥ 86400s → "Xd" (Phase 1; no absolute date string — see struct doc comment)
    internal static func relativeString(from start: Date, to end: Date) -> String {
        let seconds = Int(end.timeIntervalSince(start))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

// MARK: - Previews

#Preview("RelativeTimestampLabel — seconds ago") {
    RelativeTimestampLabel(date: .now.addingTimeInterval(-30))
        .padding()
}

#Preview("RelativeTimestampLabel — minutes ago") {
    RelativeTimestampLabel(date: .now.addingTimeInterval(-180))
        .padding()
}

#Preview("RelativeTimestampLabel — nil (never updated)") {
    RelativeTimestampLabel(date: nil)
        .padding()
}

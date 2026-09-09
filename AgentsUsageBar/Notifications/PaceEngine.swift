import Foundation

/// Last-seen utilization sample for one provider window. Held in RAM by `AggregateStore`
/// so recent-stream (B) math can compute Δu/Δt across polls. Not persisted.
public struct PaceSample: Sendable, Equatable {
    public let providerID: ProviderID
    public let windowName: String
    public let utilization: Double
    public let asOf: Date

    public init(providerID: ProviderID, windowName: String, utilization: Double, asOf: Date) {
        self.providerID = providerID
        self.windowName = windowName
        self.utilization = utilization
        self.asOf = asOf
    }
}

/// Infers a quota window's length from its display name so window-average pace (A) can
/// compute elapsed time. Recent-stream (B) does not need this — unknown names still warn
/// from Δu/Δt vs remaining time until `resetsAt`.
public enum PaceWindowDuration {
    public static let fiveHours: TimeInterval = 5 * 60 * 60
    public static let sevenDays: TimeInterval = 7 * 24 * 60 * 60

    /// - Returns: seconds, or `nil` when the name does not encode a known period
    ///   (Gemini model ids, Grok `"billing"`, etc.).
    public static func seconds(forName name: String) -> TimeInterval? {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }

        let lastToken = lower.split(whereSeparator: { $0 == " " || $0 == "/" }).last.map(String.init) ?? lower
        switch lastToken {
        case "primary":
            return fiveHours
        case "secondary", "weekly", "week", "wk":
            return sevenDays
        default:
            break
        }
        if lower == "primary" || lower.hasSuffix(" primary") { return fiveHours }
        if lower == "secondary" || lower.hasSuffix(" secondary") { return sevenDays }

        return parseEmbedded(lower)
    }

    /// First `(\d+)\s*h(r|ours?)?` or `(\d+)\s*d` with a non-alnum (or start/end) boundary
    /// so `"gemini-2.5-pro"` does not parse as 2 hours.
    static func parseEmbedded(_ lower: String) -> TimeInterval? {
        let chars = Array(lower)
        var i = 0
        while i < chars.count {
            if chars[i].isNumber {
                let start = i
                while i < chars.count && chars[i].isNumber { i += 1 }
                let digits = String(chars[start..<i])
                skipSpaces(&i, chars)
                guard i < chars.count, chars[i] == "h" || chars[i] == "d" else {
                    continue
                }
                let unit = chars[i]
                let afterUnit = i + 1
                if unit == "h" {
                    var consumed = afterUnit
                    // Optional "r" / "ours" / "our"
                    if consumed < chars.count && chars[consumed] == "r" {
                        consumed += 1
                    } else if remaining(chars, from: consumed).hasPrefix("ours") {
                        consumed += 4
                    } else if remaining(chars, from: consumed).hasPrefix("our") {
                        consumed += 3
                    }
                    if isBoundary(before: start, after: consumed, chars), let n = Double(digits), n > 0 {
                        return n * 3600
                    }
                } else {
                    // days: require boundary after `d` so "d" in the middle of a word is ignored.
                    if isBoundary(before: start, after: afterUnit, chars), let n = Double(digits), n > 0 {
                        return n * 86400
                    }
                }
                continue
            }
            i += 1
        }
        return nil
    }

    private static func skipSpaces(_ i: inout Int, _ chars: [Character]) {
        while i < chars.count && chars[i] == " " { i += 1 }
    }

    private static func remaining(_ chars: [Character], from i: Int) -> String {
        guard i < chars.count else { return "" }
        return String(chars[i...])
    }

    private static func isBoundary(before: Int, after: Int, _ chars: [Character]) -> Bool {
        let leftOK = before == 0 || !chars[before - 1].isLetter && !chars[before - 1].isNumber
        let rightOK = after >= chars.count || !chars[after].isLetter && !chars[after].isNumber
        return leftOK && rightOK
    }
}

/// Pure engine: warn when a quota window is on pace to hit 100% before reset.
///
/// **A — window pace:** `utilization / elapsed` would exhaust remaining quota before
/// `resetsAt`. Requires a known window length.
/// **B — recent stream:** `Δutilization / Δtime` across the last two samples would
/// exhaust remaining quota before `resetsAt`. Works for any named window with a reset.
///
/// One decision per `(provider, window)` per call; A and B collapse to a single fire.
public struct PaceEngine: Sendable {

    /// Floor on elapsed fraction of the window before A is trusted (avoids 1% in 10s rockets).
    public static let minElapsedFraction: Double = 0.02
    public static let minElapsedSeconds: TimeInterval = 60
    public static let maxElapsedFloor: TimeInterval = 2 * 60 * 60

    /// Recent-stream (B) floors.
    public static let minRecentDeltaSeconds: TimeInterval = 60
    public static let minRecentDeltaUtilization: Double = 0.03

    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Evaluates snapshots and returns pace decisions plus the samples to keep for the next poll.
    public func decisions(
        for snapshots: [UsageSnapshot],
        now: Date,
        previous: [PaceSample],
        snoozedUntilDay: [ProviderID: String],
        alreadyFired: [ProviderID: Set<String>],
        enabled: Bool
    ) -> (decisions: [NotificationDecision], nextSamples: [PaceSample]) {
        let today = TodayHelper.formatYYYYMMDD(now, calendar: calendar)
        var nextSamples: [PaceSample] = []
        var decisions: [NotificationDecision] = []

        let prevIndex: [PaceSample.Key: PaceSample] = Dictionary(
            previous.map { ($0.key, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        for snap in snapshots {
            if snap.raw["note"] == ThresholdEngine.degradedTag { continue }
            guard let windows = snap.quotaWindows else { continue }

            let snoozed = snoozedUntilDay[snap.providerID] == today
            let fired = alreadyFired[snap.providerID] ?? []

            for window in windows {
                guard let util = window.utilization, let resetsAt = window.resetsAt else { continue }
                let clamped = min(max(util, 0), 1)
                nextSamples.append(
                    PaceSample(
                        providerID: snap.providerID,
                        windowName: window.name,
                        utilization: clamped,
                        asOf: now
                    )
                )

                guard enabled, !snoozed else { continue }
                guard clamped > 0, clamped < 1 else { continue }
                guard !fired.contains(window.name) else { continue }

                let remaining = resetsAt.timeIntervalSince(now)
                guard remaining > 0 else { continue }

                let prev = prevIndex[PaceSample.Key(providerID: snap.providerID, windowName: window.name)]
                let windowPace = isWindowPaceToCap(
                    utilization: clamped,
                    remaining: remaining,
                    windowName: window.name
                )
                let recentPace = isRecentStreamToCap(
                    utilization: clamped,
                    remaining: remaining,
                    previous: prev,
                    now: now
                )
                guard windowPace || recentPace else { continue }

                let rateETA: TimeInterval
                if recentPace, let prev {
                    let dt = now.timeIntervalSince(prev.asOf)
                    let du = clamped - prev.utilization
                    rateETA = du > 0 && dt > 0 ? (1 - clamped) / (du / dt) : remaining
                } else if let duration = PaceWindowDuration.seconds(forName: window.name) {
                    let elapsed = duration - remaining
                    rateETA = elapsed > 0 ? (1 - clamped) / (clamped / elapsed) : remaining
                } else {
                    rateETA = remaining
                }

                decisions.append(
                    makeDecision(
                        snap: snap,
                        window: window,
                        today: today,
                        eta: rateETA,
                        remaining: remaining
                    )
                )
            }
        }

        return (decisions, nextSamples)
    }

    // MARK: - A / B

    func isWindowPaceToCap(utilization: Double, remaining: TimeInterval, windowName: String) -> Bool {
        guard let duration = PaceWindowDuration.seconds(forName: windowName) else { return false }
        let elapsed = duration - remaining
        let minElapsed = min(
            max(duration * Self.minElapsedFraction, Self.minElapsedSeconds),
            Self.maxElapsedFloor
        )
        guard elapsed >= minElapsed, elapsed > 0, utilization > 0 else { return false }
        let rate = utilization / elapsed
        let timeToCap = (1 - utilization) / rate
        return timeToCap < remaining
    }

    func isRecentStreamToCap(
        utilization: Double,
        remaining: TimeInterval,
        previous: PaceSample?,
        now: Date
    ) -> Bool {
        guard let previous else { return false }
        let dt = now.timeIntervalSince(previous.asOf)
        let du = utilization - previous.utilization
        guard dt >= Self.minRecentDeltaSeconds, du >= Self.minRecentDeltaUtilization else { return false }
        let rate = du / dt
        guard rate > 0 else { return false }
        let timeToCap = (1 - utilization) / rate
        return timeToCap < remaining
    }

    // MARK: - Copy

    func makeDecision(
        snap: UsageSnapshot,
        window: QuotaWindow,
        today: String,
        eta: TimeInterval,
        remaining: TimeInterval
    ) -> NotificationDecision {
        let displayName = snap.providerID.displayHint
        let slug = Self.slug(window.name)
        let id = "\(snap.providerID.rawValue):\(today):pace:\(slug)"
        let title = "\(displayName) \(window.name) limit at risk"
        let body = "At this rate it runs out in \(Self.compactDuration(eta)); window resets in \(Self.compactDuration(remaining))."
        return NotificationDecision(
            id: id,
            title: title,
            body: body,
            providerID: snap.providerID,
            displayName: displayName,
            band: .warning,
            windowName: window.name
        )
    }

    public static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "." || ch == "-" { return ch }
            return "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "window" : collapsed
    }

    public static func compactDuration(_ interval: TimeInterval) -> String {
        let t = max(0, interval)
        if t < 60 { return "<1m" }
        if t < 3600 {
            return "\(max(1, Int((t / 60).rounded())))m"
        }
        if t < 86400 {
            let hours = t / 3600
            let h = Int(hours)
            let m = Int(((t - Double(h) * 3600) / 60).rounded())
            if h == 0 { return "\(max(1, m))m" }
            if m == 0 { return "\(h)h" }
            return "\(h)h \(m)m"
        }
        let days = t / 86400
        let d = Int(days)
        let h = Int(((t - Double(d) * 86400) / 3600).rounded())
        if d == 0 { return compactDuration(t) }
        if h == 0 { return "\(d)d" }
        return "\(d)d \(h)h"
    }
}

extension PaceSample {
    struct Key: Hashable {
        let providerID: ProviderID
        let windowName: String
    }

    var key: Key { Key(providerID: providerID, windowName: windowName) }
}

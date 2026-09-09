import Foundation

/// Last-seen quota window for reset detection. Held in RAM by `AggregateStore`
/// so a later poll can see `resetsAt` move forward. Not persisted.
public struct ResetSample: Sendable, Equatable {
    public let providerID: ProviderID
    public let windowName: String
    public let utilization: Double
    public let resetsAt: Date

    public init(providerID: ProviderID, windowName: String, utilization: Double, resetsAt: Date) {
        self.providerID = providerID
        self.windowName = windowName
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

/// Pure engine: notify when a quota window resets after it was at/above the
/// warning threshold (or exhausted). Idle windows stay quiet.
///
/// Fire when `resetsAt` moves forward vs the previous poll for the same
/// `(provider, window)` and the **previous** utilization was `>= warningFraction`.
/// First poll (no sample) never fires.
public struct ResetEngine: Sendable {

    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Evaluates snapshots and returns reset decisions plus the samples to keep for the next poll.
    public func decisions(
        for snapshots: [UsageSnapshot],
        now: Date,
        previous: [ResetSample],
        alreadyFired: [ProviderID: Set<String>],
        warningFraction: Double,
        enabled: Bool
    ) -> (decisions: [NotificationDecision], nextSamples: [ResetSample]) {
        let today = TodayHelper.formatYYYYMMDD(now, calendar: calendar)
        var nextSamples: [ResetSample] = []
        var decisions: [NotificationDecision] = []

        let prevIndex: [ResetSample.Key: ResetSample] = Dictionary(
            previous.map { ($0.key, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        for snap in snapshots {
            if snap.raw["note"] == ThresholdEngine.degradedTag { continue }
            guard let windows = snap.quotaWindows else { continue }

            let fired = alreadyFired[snap.providerID] ?? []

            for window in windows {
                guard let util = window.utilization, let resetsAt = window.resetsAt else { continue }
                let clamped = min(max(util, 0), 1)
                nextSamples.append(
                    ResetSample(
                        providerID: snap.providerID,
                        windowName: window.name,
                        utilization: clamped,
                        resetsAt: resetsAt
                    )
                )

                guard enabled else { continue }
                let prev = prevIndex[ResetSample.Key(providerID: snap.providerID, windowName: window.name)]
                guard let prev else { continue }
                guard resetsAt > prev.resetsAt else { continue }
                guard prev.utilization >= warningFraction else { continue }

                let key = Self.fireKey(windowName: window.name, resetsAt: prev.resetsAt)
                guard !fired.contains(key) else { continue }

                decisions.append(
                    makeDecision(
                        snap: snap,
                        window: window,
                        today: today,
                        previousResetsAt: prev.resetsAt
                    )
                )
            }
        }

        return (decisions, nextSamples)
    }

    /// Dedup token for one reset event: window name plus the **old** `resetsAt`.
    public static func fireKey(windowName: String, resetsAt: Date) -> String {
        "\(windowName):\(Int(resetsAt.timeIntervalSince1970))"
    }

    func makeDecision(
        snap: UsageSnapshot,
        window: QuotaWindow,
        today: String,
        previousResetsAt: Date
    ) -> NotificationDecision {
        let displayName = snap.providerID.displayHint
        let slug = PaceEngine.slug(window.name)
        let epoch = Int(previousResetsAt.timeIntervalSince1970)
        let id = "\(snap.providerID.rawValue):\(today):reset:\(slug):\(epoch)"
        let title = "\(displayName) \(window.name) limit reset"
        let body = "Usage is available again."
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
}

extension ResetSample {
    struct Key: Hashable {
        let providerID: ProviderID
        let windowName: String
    }

    var key: Key { Key(providerID: providerID, windowName: windowName) }
}

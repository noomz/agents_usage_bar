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

    private let dayKeys: DayKeyOwner

    public init(dayKeys: DayKeyOwner = DayKeyOwner()) {
        self.dayKeys = dayKeys
    }

    /// Evaluates snapshots and returns every reset crossing (SPEC V34), the decisions to
    /// schedule, and the samples to keep for the next poll. `enabled` only sets `notified`;
    /// a reset is reported once either way.
    public func decisions(
        for snapshots: [UsageSnapshot],
        now: Date,
        previous: [ResetSample],
        alreadyFired: [ProviderID: Set<String>],
        warningFraction: Double,
        enabled: Bool
    ) -> (decisions: [NotificationDecision], nextSamples: [ResetSample], crossings: [QuotaCrossing]) {
        let today = dayKeys.key(for: now)
        var nextSamples: [ResetSample] = []
        var decisions: [NotificationDecision] = []
        var crossings: [QuotaCrossing] = []

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

                let prev = prevIndex[ResetSample.Key(providerID: snap.providerID, windowName: window.name)]
                guard let prev else { continue }
                guard resetsAt > prev.resetsAt else { continue }
                guard prev.utilization >= warningFraction else { continue }

                let key = Self.fireKey(windowName: window.name, resetsAt: prev.resetsAt)
                guard !fired.contains(key) else { continue }

                crossings.append(
                    QuotaCrossing(
                        providerID: snap.providerID,
                        kind: .reset,
                        window: window.name,
                        fraction: prev.utilization,
                        notified: enabled,
                        stateKey: key
                    )
                )
                guard enabled else { continue }

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

        return (decisions, nextSamples, crossings)
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

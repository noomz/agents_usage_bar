import Foundation

// Folding good poll samples into the open day (SPEC V7, V8, V10, V11).

extension DayFile {
    /// The day with every sample folded in, one record per provider (V7, V11). The zone id
    /// becomes `timeZone`, the last one seen (V6). No samples leaves the day unchanged.
    public func merging(_ samples: [UsageSnapshot], at now: Date, timeZone: String) -> DayFile {
        guard !samples.isEmpty else { return self }
        var day = self
        day.timeZone = timeZone
        for sample in samples {
            if let index = day.records.firstIndex(where: { $0.provider == sample.providerID }) {
                day.records[index] = day.records[index].merging(sample, at: now)
            } else {
                day.records.append(DayRecord(provider: sample.providerID, origin: .observed).merging(sample, at: now))
            }
        }
        day.records.sort { $0.provider.rawValue < $1.provider.rawValue }
        return day
    }

    /// True when the two days differ only in `firstSeen` and `lastSeen`, which ride the next
    /// changed write instead of causing one (V15).
    public func hasSameContent(as other: DayFile) -> Bool {
        withoutSeenTimes() == other.withoutSeenTimes()
    }

    private func withoutSeenTimes() -> DayFile {
        var day = self
        for index in day.records.indices {
            day.records[index].firstSeen = nil
            day.records[index].lastSeen = nil
        }
        return day
    }
}

extension DayRecord {
    /// The record with one good sample folded in: highest totals, last balance, and per-window
    /// peak and end-of-day quota (V7, V8, V10).
    public func merging(_ sample: UsageSnapshot, at now: Date) -> DayRecord {
        var record = self
        record.tokens = highestKnown(tokens, sample.tokensToday)
        record.costUSD = highestKnown(costUSD, sample.costTodayUSD.map(Money.init))
        record.balanceUSD = sample.balanceUSD.map(Money.init) ?? balanceUSD
        for (window, fraction) in sample.quotaFractions {
            record.quota[window] = record.quota[window]?.merging(fraction.value, resetsAt: fraction.resetsAt)
                ?? QuotaDay(peak: fraction.value, peakResetsAt: fraction.resetsAt, endOfDay: fraction.value)
        }
        record.firstSeen = firstSeen ?? now
        record.lastSeen = now
        return record
    }
}

extension QuotaDay {
    /// A window that resets during the day keeps its highest value across the day (V8).
    func merging(_ fraction: Double, resetsAt: Date?) -> QuotaDay {
        guard fraction > peak else {
            return QuotaDay(peak: peak, peakResetsAt: peakResetsAt, endOfDay: fraction)
        }
        return QuotaDay(peak: fraction, peakResetsAt: resetsAt, endOfDay: fraction)
    }
}

extension UsageSnapshot {
    /// The window name a provider's single quota is filed under when it reports no windows.
    public static let providerQuotaWindow = "quota"

    /// Quota fractions by window name (V8). Windows without utilization are skipped.
    var quotaFractions: [String: (value: Double, resetsAt: Date?)] {
        let windows = (quotaWindows ?? []).compactMap { window in
            window.utilization.map { (window.name, (value: $0, resetsAt: window.resetsAt)) }
        }
        if !windows.isEmpty {
            return Dictionary(windows, uniquingKeysWith: { first, _ in first })
        }
        guard let quota else { return [:] }
        return [Self.providerQuotaWindow: (value: quota.fraction, resetsAt: nil)]
    }
}

/// The higher of two values where nil is unknown, never zero (V7).
private func highestKnown<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
    guard let lhs, let rhs else { return lhs ?? rhs }
    return max(lhs, rhs)
}

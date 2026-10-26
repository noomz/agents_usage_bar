import Foundation

import CryptoKit

// Folding good poll samples into the open day (SPEC V7–V11, V21, V22, V25).

extension DayFile {
    /// The day with every sample folded in, one record per provider (V7, V11). The zone id
    /// becomes `timeZone`, the last one seen (V6). No samples leaves the day unchanged.
    /// `accountKey` turns a provider's own account id into its account key (V21).
    public func merging(
        _ samples: [UsageSnapshot],
        at now: Date,
        timeZone: String,
        accountKey: (String) -> String
    ) -> DayFile {
        guard !samples.isEmpty else { return self }
        var day = self
        day.timeZone = timeZone
        for sample in samples {
            if let index = day.records.firstIndex(where: { $0.provider == sample.providerID }) {
                day.records[index] = day.records[index].merging(sample, at: now, accountKey: accountKey)
            } else {
                day.records.append(
                    DayRecord(provider: sample.providerID, origin: .observed)
                        .merging(sample, at: now, accountKey: accountKey))
            }
        }
        day.records.sort { $0.provider.rawValue < $1.provider.rawValue }
        return day
    }

    /// The day with one provider's backfilled record folded in and the provider marked
    /// checked (V29). It tops up a record already there (V31) or adds a new one that carries
    /// no quota or seen times (V30) and whose accounts are assumed, with no per-account cost
    /// (V62). Events are never touched (V32).
    public func backfilling(_ record: DayRecord) -> DayFile {
        var day = self
        if let index = day.records.firstIndex(where: { $0.provider == record.provider }) {
            day.records[index] = day.records[index].toppedUp(by: record)
        } else {
            var added = record
            added.origin = .backfilled
            added.quota = [:]
            added.firstSeen = nil
            added.lastSeen = nil
            for index in added.accounts.indices {
                added.accounts[index].quota = [:]
                added.accounts[index].costUSD = nil
                added.accounts[index].billingModelAssumed = true
            }
            day.records.append(added)
            day.records.sort { $0.provider.rawValue < $1.provider.rawValue }
        }
        if !day.backfillChecked.contains(record.provider) {
            day.backfillChecked.append(record.provider)
        }
        return day
    }

    /// True when the day has no record and no event, so a new file is not worth writing.
    public var isEmpty: Bool {
        records.isEmpty && events.isEmpty
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
    /// peak and end-of-day quota, and each account seen (V7–V10). A cost counts as estimated
    /// when any sample that reported one was estimated.
    public func merging(_ sample: UsageSnapshot, at now: Date, accountKey: (String) -> String) -> DayRecord {
        var record = self
        record.tokens = highestKnown(tokens, sample.tokensToday)
        record.costUSD = highestKnown(costUSD, sample.costTodayUSD.map(Money.init))
        record.costEstimated = costEstimated || (sample.costTodayUSD != nil && sample.costEstimated)
        record.balanceUSD = sample.balanceUSD.map(Money.init) ?? balanceUSD
        record.quota = quota.merging(sample.quotaFractions)
        for account in sample.dayAccounts(accountKey: accountKey) {
            if let index = record.accounts.firstIndex(where: { $0.key == account.key }) {
                record.accounts[index] = record.accounts[index].merging(account)
            } else {
                record.accounts.append(account)
            }
        }
        record.accounts.sort { $0.key < $1.key }
        record.firstSeen = firstSeen ?? now
        record.lastSeen = now
        return record
    }

    /// The record with a backfill's `tokens`, `costUSD`, and account tokens max-merged in (V7,
    /// V9, V31). A cost the backfill raised takes its estimated flag; everything else stays.
    func toppedUp(by backfill: DayRecord) -> DayRecord {
        var record = self
        record.tokens = highestKnown(tokens, backfill.tokens)
        let cost = highestKnown(costUSD, backfill.costUSD)
        if cost != costUSD {
            record.costEstimated = backfill.costEstimated
        }
        record.costUSD = cost
        for account in backfill.accounts {
            guard let index = record.accounts.firstIndex(where: { $0.key == account.key }) else { continue }
            record.accounts[index].tokens = highestKnown(record.accounts[index].tokens, account.tokens)
        }
        return record
    }
}

extension DayAccount {
    /// The key every provider's single account uses, and Claude's `~/.claude` account.
    public static let defaultKey = "default"

    /// Folds a newer sample of the same account: the newest label, billing model, and plan
    /// (V22, V25), the highest cost (V7), the newest known tokens, which each poll recomputes
    /// for the whole day from current session owners (V9), and per-window peak and end-of-day
    /// quota (V8).
    func merging(_ newer: DayAccount) -> DayAccount {
        var account = newer
        account.costUSD = highestKnown(costUSD, newer.costUSD)
        account.tokens = newer.tokens ?? tokens
        account.quota = quota.merging(newer.quota.mapValues { (value: $0.peak, resetsAt: $0.peakResetsAt) })
        return account
    }

    /// A short salted hash of a provider's own account id, so history never holds the raw
    /// id and nobody without the salt can link it (V21, ADR 0003).
    public static func key(forAccountID accountID: String, salt: Data) -> String {
        let digest = SHA256.hash(data: salt + Data(accountID.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The stored label: never an email and never derived from a raw account id (V22).
    static func label(name: String, key: String, plan: String?, planIsUnique: Bool, hashed: Bool) -> String {
        if !name.contains("@"), !(hashed && name.hasPrefix("acct-")) {
            return name
        }
        if let plan, planIsUnique {
            return plan
        }
        return "acct-" + key.prefix(4)
    }
}

extension [String: QuotaDay] {
    /// Each window's peak with its reset time, and the last value as end-of-day (V8).
    func merging(_ fractions: [String: (value: Double, resetsAt: Date?)]) -> [String: QuotaDay] {
        var merged = self
        for (window, fraction) in fractions {
            merged[window] = merged[window]?.merging(fraction.value, resetsAt: fraction.resetsAt)
                ?? QuotaDay(peak: fraction.value, peakResetsAt: fraction.resetsAt, endOfDay: fraction.value)
        }
        return merged
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
        Self.quotaFractions(windows: quotaWindows, quota: quota)
    }

    private static func quotaFractions(
        windows: [QuotaWindow]?,
        quota: Quota?
    ) -> [String: (value: Double, resetsAt: Date?)] {
        let fractions = (windows ?? []).compactMap { window in
            window.utilization.map { (window.name, (value: $0, resetsAt: window.resetsAt)) }
        }
        if !fractions.isEmpty {
            return Dictionary(fractions, uniquingKeysWith: { first, _ in first })
        }
        guard let quota else { return [:] }
        return [providerQuotaWindow: (value: quota.fraction, resetsAt: nil)]
    }

    /// The accounts this sample saw (V9). A provider without `accounts` is one account. With
    /// no billing info, a local runtime is local and any other provider metered (I6).
    func dayAccounts(accountKey: (String) -> String) -> [DayAccount] {
        let fallback: BillingModel = providerID.isLocalRuntime ? .local : .metered
        guard let accounts, !accounts.isEmpty else {
            // Claude session reads and hook mode agree on `default`; a hashed key gets a
            // plan or key-prefix label (V22).
            let key = accountInfo?.accountID.map(accountKey) ?? DayAccount.defaultKey
            let label = accountInfo?.accountID == nil ? key : accountInfo?.plan ?? "acct-" + key.prefix(4)
            return [DayAccount(
                key: key,
                label: label,
                billingModel: accountInfo?.billingModel ?? fallback,
                plan: accountInfo?.plan,
                quota: [:].merging(quotaFractions)
            )]
        }
        let plans = accounts.compactMap { $0.accountInfo?.plan }
        return accounts.map { account in
            let info = account.accountInfo
            let key = info?.accountID.map(accountKey) ?? account.name
            return DayAccount(
                key: key,
                label: DayAccount.label(
                    name: account.name, key: key, plan: info?.plan,
                    planIsUnique: plans.filter { $0 == info?.plan }.count == 1,
                    hashed: info?.accountID != nil),
                billingModel: info?.billingModel ?? fallback,
                plan: info?.plan,
                costUSD: account.costTodayUSD.map(Money.init),
                tokens: account.tokensToday,
                quota: [:].merging(Self.quotaFractions(windows: account.quotaWindows, quota: account.quota))
            )
        }
    }
}

/// The higher of two values where nil is unknown, never zero (V7).
private func highestKnown<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
    guard let lhs, let rhs else { return lhs ?? rhs }
    return max(lhs, rhs)
}

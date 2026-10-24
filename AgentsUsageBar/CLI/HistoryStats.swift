import Foundation

/// The day keys `aub stats` covers (SPEC V44): `--days`, `--since`, and `--until`, ending
/// today by default. `today` is the open day (V45).
public struct StatsRange: Sendable, Equatable {
    public let keys: [String]
    public let today: String

    public static let defaultDays = 14
    /// Up to this many days the trend draws one character per day; beyond, equal buckets.
    static let maxTrendCells = 30

    public var isTodayOpen: Bool { keys.last == today }

    /// Days per trend character: 1 up to `maxTrendCells` days, else the smallest bucket
    /// that fits (V44).
    public var bucketSize: Int {
        max(1, (keys.count + Self.maxTrendCells - 1) / Self.maxTrendCells)
    }

    /// Resolves the flags against `today`. `--until` later than today ends at today. With
    /// `oldest`, no `--days` and no `--since` start at it instead of 14 days back: export
    /// covers every retained day by default (V47).
    public static func resolve(
        today: String,
        days: Int?,
        since: String?,
        until: String?,
        oldest: String? = nil
    ) -> Result<StatsRange, AUBParseError> {
        let last: String
        let first: String
        switch (since, until) {
        case let (since?, until?):
            if days != nil { return .failure(.unexpectedArgument("--days")) }
            first = since
            last = min(until, today)
        case let (since?, nil):
            first = since
            last = days.flatMap { keyMath.key(since, addingDays: $0 - 1) }.map { min($0, today) } ?? today
        case let (nil, until):
            last = min(until ?? today, today)
            if days == nil, let oldest {
                first = min(oldest, last)
            } else {
                first = keyMath.key(last, addingDays: -((days ?? defaultDays) - 1)) ?? last
            }
        }
        guard first <= last else { return .failure(.emptyRange(first, last)) }
        var keys = [first]
        while let next = keyMath.key(keys[keys.count - 1], addingDays: 1), next <= last {
            keys.append(next)
        }
        return .success(StatsRange(keys: keys, today: today))
    }

    /// True for a real `yyyy-MM-dd` date (V2).
    public static func isDayKey(_ text: String) -> Bool {
        text.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil && keyMath.key(text, addingDays: 0) == text
    }

    /// Day keys are calendar dates, so any fixed zone does the arithmetic.
    private static let keyMath = DayKeyOwner(timeZone: TimeZone(identifier: "UTC")!)
}

/// One provider's history over a `StatsRange`, as `aub stats` shows it (V42–V45).
struct ProviderStats {
    /// The provider's billing models in range. A mixed provider is shown like a
    /// subscription one in the summary trend (V43).
    enum Kind: Equatable {
        case metered, subscription, mixed, local
    }

    typealias Total = SpendTotal

    /// One trend character's worth of days (V43–V45).
    enum Cell: Equatable {
        case value(Double)
        case present
        /// No record for any day in the cell.
        case gap
        /// Every day in the cell has a record but no value for the plotted metric (V64).
        case noValue
        /// A bucket mixing values, gaps, and no-value days: marked, never drawn low.
        case incomplete
    }

    let id: ProviderID
    let kind: Kind
    /// One per range key; nil is a gap.
    let records: [DayRecord?]
    /// Distinct subscription plan names in range, sorted.
    let plans: [String]

    init(id: ProviderID, records: [DayRecord?]) {
        self.id = id
        self.records = records
        let accounts = records.compactMap { $0 }.flatMap(\.accounts)
        let metered = accounts.contains { $0.billingModel == .metered }
        let subscription = accounts.contains { $0.billingModel == .subscription }
        if id.isLocalRuntime || (!accounts.isEmpty && accounts.allSatisfy { $0.billingModel == .local }) {
            kind = .local
        } else if metered && subscription {
            kind = .mixed
        } else if subscription {
            kind = .subscription
        } else {
            kind = .metered
        }
        plans = Set(accounts.filter { $0.billingModel == .subscription }.compactMap(\.plan)).sorted()
    }

    var seenDays: Int { records.count(where: { $0 != nil }) }

    var hasSpend: Bool { kind == .metered || kind == .mixed }
    var hasValue: Bool { kind == .subscription || kind == .mixed }

    /// Metered spend (V26). A gap, or a day with a metered account and unknown spend,
    /// makes it incomplete.
    var spend: Total { total(\.spend, applies: \.hasMetered) }

    /// API-equivalent value of subscription accounts (V26). Never added to spend.
    var value: Total { total(\.value, applies: \.hasSubscription) }

    private func total(_ amount: KeyPath<DayCostSplit, Money?>, applies: KeyPath<DayCostSplit, Bool>) -> Total {
        .sum(records, amount, applies: applies)
    }

    /// Sum of known tokens, nil when no day reports them.
    var tokens: Int? {
        let known = records.compactMap { $0?.tokens }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// The highest window peak in range, with its window name (V43).
    var peak: (fraction: Double, window: String)? {
        records.compactMap { $0.flatMap(Self.peak) }.max { $0.fraction < $1.fraction }
    }

    /// A record's highest window peak; ties go to the first window name.
    static func peak(_ record: DayRecord) -> (fraction: Double, window: String)? {
        record.quota.sorted { $0.key < $1.key }
            .max { $0.value.peak < $1.value.peak }
            .map { ($0.value.peak, $0.key) }
    }

    /// Trend characters, oldest first, `bucketSize` days each and the newest bucket ending at
    /// the last key (V43, V44). Metered rows plot spend, subscription and mixed rows the
    /// day's highest window peak, local rows presence. A recorded day without that value
    /// (no quota on a backfilled day, nil spend) is `noValue`, never a gap (V64).
    func trend(bucketSize: Int) -> [Cell] {
        // Outer nil is a gap, inner nil a recorded day with no value.
        let daily: [Double??] = records.map { record in
            guard let record else { return nil }
            switch kind {
            case .metered: return .some(record.costSplit.spend.map { NSDecimalNumber(decimal: $0.amount).doubleValue })
            case .subscription, .mixed: return .some(Self.peak(record)?.fraction)
            case .local: return 1
            }
        }
        var buckets: [[Double??]] = []
        var end = daily.count
        while end > 0 {
            let start = max(0, end - bucketSize)
            buckets.insert(Array(daily[start..<end]), at: 0)
            end = start
        }
        return buckets.map { bucket in
            let recorded = bucket.compactMap { $0 }
            if recorded.isEmpty { return .gap }
            if kind == .local { return .present }
            let known = recorded.compactMap { $0 }
            if known.isEmpty, recorded.count == bucket.count { return .noValue }
            if known.count < bucket.count { return .incomplete }
            return .value(kind == .metered ? known.reduce(0, +) : known.max()!)
        }
    }
}

extension ProviderStats {
    /// Every provider with a record in range, in `provider-order` (V42). Local runtimes
    /// only when `includeLocal`.
    static func collect(
        _ days: [DayFile],
        range: StatsRange,
        includeLocal: Bool,
        only: ProviderID? = nil,
        order: [ProviderID] = []
    ) -> [ProviderStats] {
        let byKey = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(range.keys.flatMap { byKey[$0]?.records.map(\.provider) ?? [] })
        let stats = ids.filter { only == nil || $0 == only }.map { id in
            ProviderStats(id: id, records: range.keys.map { key in
                byKey[key]?.records.first { $0.provider == id }
            })
        }
        return ProviderID.ordered(
            stats.filter { includeLocal || only != nil || $0.kind != .local }, id: \.id, preference: order)
    }
}

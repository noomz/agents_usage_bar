import Foundation

/// What provider detail shows for one provider, range, and account (SPEC V54). Selecting an
/// account narrows every tab to it: its cost, its quota windows, and the days it was seen.
/// Totals the provider does not report per account stay unknown, never split (V12). Split
/// keeps every account and breaks cost and quota into accounts (V68).
struct DashboardProviderDetail {
    enum Tab: Hashable, CaseIterable {
        case cost, tokens, quota, accounts
    }

    /// Spend and value are separate series with separate totals, never summed (V26).
    enum Series: String {
        case spend = "Spend"
        case value = "Value"
    }

    struct Account: Identifiable {
        let key: String
        /// The newest label seen for the key (V22).
        let label: String
        let billingModel: BillingModel
        let plan: String?
        /// The account's own days in range; nil is a day it was not seen.
        let stats: ProviderStats
        var id: String { key }
    }

    /// Whose cost a point is: the whole day, or with split on, one account or the rest (V68).
    enum Part: Hashable {
        case whole
        case account(String)
        case unattributed
    }

    struct CostPoint: Identifiable, Equatable {
        let key: String
        let series: Series
        var part: Part = .whole
        let amount: Double
        let estimated: Bool
        let backfilled: Bool
        var id: String { "\(key) \(series.rawValue) \(part)" }
    }

    struct TokenPoint: Identifiable, Equatable {
        let key: String
        var part: Part = .whole
        let tokens: Int
        let backfilled: Bool
        var id: String { "\(key) \(part)" }
    }

    /// One day of one window: a bar from the end-of-day fraction up to the peak (V54).
    struct QuotaBar: Identifiable, Equatable {
        let key: String
        let window: String
        let peak: Double
        let endOfDay: Double
        /// With split on, the account the bar belongs to (V68).
        var account: String?
        var id: String { "\(key) \(window) \(account ?? "")" }
    }

    let range: StatsRange
    /// The selected account key, nil for every account. A key not seen in range is dropped.
    let account: String?
    /// Split by account: only with every account shown and more than one seen (V68).
    let split: Bool
    /// The provider's days in range, narrowed to `account`. Nil is a gap.
    let stats: ProviderStats
    /// Every account seen in range, for the picker, in first-seen order.
    let accounts: [Account]
    /// The provider's usage events in range, newest first. With an account selected, the
    /// provider-level events stay and other accounts' events go.
    let events: [UsageEvent]

    init(id: ProviderID, days: [DayFile], range: StatsRange, account: String? = nil, split: Bool = false) {
        self.range = range
        let byKey = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let records = range.keys.map { byKey[$0]?.records.first { $0.provider == id } }

        let seen = Self.newestAccounts(records)
        accounts = seen.map { newest in
            Account(
                key: newest.key, label: newest.label, billingModel: newest.billingModel, plan: newest.plan,
                stats: ProviderStats(id: id, records: records.map { $0.flatMap { Self.narrow($0, to: newest.key) } }))
        }

        let selected = account.flatMap { key in seen.contains { $0.key == key } ? key : nil }
        self.account = selected
        self.split = split && selected == nil && accounts.count > 1
        stats = accounts.first { $0.key == selected }?.stats ?? ProviderStats(id: id, records: records)

        let keys = Set(range.keys)
        events = days.filter { keys.contains($0.date) }.flatMap(\.events)
            .filter { $0.provider == id && (selected == nil || $0.account == nil || $0.account == selected) }
            .sorted { $0.time > $1.time }
    }

    /// Every account in `records`, in first-seen order, each as its newest entry (V22).
    static func newestAccounts(_ records: [DayRecord?]) -> [DayAccount] {
        var order: [String] = []
        var newest: [String: DayAccount] = [:]
        for account in records.compactMap({ $0 }).flatMap(\.accounts) {
            if newest[account.key] == nil { order.append(account.key) }
            newest[account.key] = account
        }
        return order.compactMap { newest[$0] }
    }

    /// A record seen through one account, or nil when the account was not seen that day.
    /// Tokens, cost, and balance carry over only when the account is the record's only one
    /// or reports its own tokens or cost (V9); otherwise they are unknown.
    static func narrow(_ record: DayRecord, to key: String) -> DayRecord? {
        guard let account = record.accounts.first(where: { $0.key == key }) else { return nil }
        let alone = record.accounts.count == 1
        var narrowed = record
        narrowed.tokens = alone ? record.tokens : account.tokens
        narrowed.costUSD = account.costUSD ?? (alone ? record.costUSD : nil)
        narrowed.balanceUSD = alone ? record.balanceUSD : nil
        narrowed.quota = account.quota
        narrowed.accounts = [account]
        return narrowed
    }

    /// The first tab is named by billing model (V54). Local runtimes show presence (V56).
    var costTabTitle: String {
        switch stats.kind {
        case .metered: return "Spend"
        case .subscription: return "Value"
        case .mixed: return "Spend & value"
        case .local: return "Presence"
        }
    }

    /// Known spend and value per day, two series (V54); with split on, one point per account
    /// part, stacked within its series (V68).
    var costPoints: [CostPoint] {
        zip(range.keys, stats.records).flatMap { key, record -> [CostPoint] in
            guard let record else { return [] }
            if self.split { return splitPoints(key, record) }
            let split = record.costSplit
            let series: [(Series, Money?)] = [
                (.spend, stats.hasSpend ? split.spend : nil),
                (.value, stats.hasValue ? split.value : nil),
            ]
            return series.compactMap { series, money in
                money.map {
                    CostPoint(
                        key: key, series: series, amount: NSDecimalNumber(decimal: $0.amount).doubleValue,
                        estimated: split.estimated, backfilled: record.origin == .backfilled)
                }
            }
        }
    }

    private func splitPoints(_ key: String, _ record: DayRecord) -> [CostPoint] {
        record.costSegments.compactMap { segment in
            let series: Series = segment.billingModel == .metered ? .spend : .value
            guard series == .spend ? stats.hasSpend : stats.hasValue else { return nil }
            return CostPoint(
                key: key, series: series, part: segment.account.map(Part.account) ?? .unattributed,
                amount: NSDecimalNumber(decimal: segment.amount.amount).doubleValue,
                estimated: record.costEstimated, backfilled: record.origin == .backfilled)
        }
    }

    /// Known tokens per day; with split on, one point per account part, stacked (V68).
    var tokenPoints: [TokenPoint] {
        zip(range.keys, stats.records).flatMap { key, record -> [TokenPoint] in
            guard let record else { return [] }
            let backfilled = record.origin == .backfilled
            guard split else {
                return record.tokens.map { [TokenPoint(key: key, tokens: $0, backfilled: backfilled)] } ?? []
            }
            return record.tokenSegments.map { segment in
                TokenPoint(key: key, part: segment.account.map(Part.account) ?? .unattributed,
                           tokens: segment.tokens, backfilled: backfilled)
            }
        }
    }

    /// Known tokens in range; incomplete when a day is a gap or has unknown tokens.
    var tokens: (total: Int?, incomplete: Bool) {
        (stats.tokens, stats.records.contains { $0?.tokens == nil })
    }

    /// Window names seen in range, sorted. With split on, the accounts' own names: a record
    /// keys `<label> <window>` while each account keys its bare window (V69).
    var quotaWindows: [String] {
        let records = split ? accounts.flatMap(\.stats.records) : stats.records
        return Set(records.compactMap { $0 }.flatMap(\.quota.keys)).sorted()
    }

    /// One bar per day, or with split on, one per account per day (V68).
    func quotaBars(_ window: String) -> [QuotaBar] {
        guard split else { return Self.quotaBars(window, stats, account: nil, keys: range.keys) }
        return accounts.flatMap { Self.quotaBars(window, $0.stats, account: $0.key, keys: range.keys) }
    }

    private static func quotaBars(_ window: String, _ stats: ProviderStats, account: String?, keys: [String]) -> [QuotaBar] {
        zip(keys, stats.records).compactMap { key, record in
            guard let quota = record?.quota[window] else { return nil }
            return QuotaBar(key: key, window: window, peak: quota.peak, endOfDay: quota.endOfDay, account: account)
        }
    }

    /// The newest label for an account key (V22).
    func label(_ part: Part) -> String {
        switch part {
        case .whole: return ""
        case .account(let key): return accounts.first { $0.key == key }?.label ?? key
        case .unattributed: return "unattributed"
        }
    }

    /// Days with no record (or the selected account not seen): grey "no data" bands (V56).
    /// A recorded day without a value draws nothing, never a band (V64).
    var gapKeys: [String] {
        zip(range.keys, stats.records).compactMap { key, record in record == nil ? key : nil }
    }

    /// The accounts the Accounts tab lists.
    var shownAccounts: [Account] {
        accounts.filter { account == nil || $0.key == account }
    }
}

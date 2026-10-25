import Foundation

/// What provider detail shows for one provider, range, and account (SPEC V54). Selecting an
/// account narrows every tab to it: its cost, its quota windows, and the days it was seen.
/// Totals the provider does not report per account stay unknown, never split (V12).
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

    struct CostPoint: Identifiable, Equatable {
        let key: String
        let series: Series
        let amount: Double
        let estimated: Bool
        let backfilled: Bool
        var id: String { "\(key) \(series.rawValue)" }
    }

    struct TokenPoint: Identifiable, Equatable {
        let key: String
        let tokens: Int
        let backfilled: Bool
        var id: String { key }
    }

    /// One day of one window: a bar from the end-of-day fraction up to the peak (V54).
    struct QuotaBar: Identifiable, Equatable {
        let key: String
        let window: String
        let peak: Double
        let endOfDay: Double
        var id: String { "\(key) \(window)" }
    }

    let range: StatsRange
    /// The selected account key, nil for every account. A key not seen in range is dropped.
    let account: String?
    /// The provider's days in range, narrowed to `account`. Nil is a gap.
    let stats: ProviderStats
    /// Every account seen in range, for the picker, in first-seen order.
    let accounts: [Account]
    /// The provider's usage events in range, newest first. With an account selected, the
    /// provider-level events stay and other accounts' events go.
    let events: [UsageEvent]

    init(id: ProviderID, days: [DayFile], range: StatsRange, account: String? = nil) {
        self.range = range
        let byKey = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let records = range.keys.map { byKey[$0]?.records.first { $0.provider == id } }

        var order: [String] = []
        var newest: [String: DayAccount] = [:]
        for account in records.compactMap({ $0 }).flatMap(\.accounts) {
            if newest[account.key] == nil { order.append(account.key) }
            newest[account.key] = account
        }
        accounts = order.compactMap { key in
            newest[key].map {
                Account(
                    key: key, label: $0.label, billingModel: $0.billingModel, plan: $0.plan,
                    stats: ProviderStats(id: id, records: records.map { $0.flatMap { Self.narrow($0, to: key) } }))
            }
        }

        let selected = account.flatMap { key in order.contains(key) ? key : nil }
        self.account = selected
        stats = accounts.first { $0.key == selected }?.stats ?? ProviderStats(id: id, records: records)

        let keys = Set(range.keys)
        events = days.filter { keys.contains($0.date) }.flatMap(\.events)
            .filter { $0.provider == id && (selected == nil || $0.account == nil || $0.account == selected) }
            .sorted { $0.time > $1.time }
    }

    /// A record seen through one account, or nil when the account was not seen that day.
    /// Tokens, cost, and balance carry over only when the account is the record's only one
    /// or reports its own cost (V9); otherwise they are unknown.
    static func narrow(_ record: DayRecord, to key: String) -> DayRecord? {
        guard let account = record.accounts.first(where: { $0.key == key }) else { return nil }
        let alone = record.accounts.count == 1
        var narrowed = record
        narrowed.tokens = alone ? record.tokens : nil
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

    /// Known spend and value per day, two series (V54).
    var costPoints: [CostPoint] {
        zip(range.keys, stats.records).flatMap { key, record -> [CostPoint] in
            guard let record else { return [] }
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

    var tokenPoints: [TokenPoint] {
        zip(range.keys, stats.records).compactMap { key, record in
            guard let record, let tokens = record.tokens else { return nil }
            return TokenPoint(key: key, tokens: tokens, backfilled: record.origin == .backfilled)
        }
    }

    /// Known tokens in range; incomplete when a day is a gap or has unknown tokens.
    var tokens: (total: Int?, incomplete: Bool) {
        (stats.tokens, stats.records.contains { $0?.tokens == nil })
    }

    /// Window names seen in range, sorted.
    var quotaWindows: [String] {
        Set(stats.records.compactMap { $0 }.flatMap(\.quota.keys)).sorted()
    }

    func quotaBars(_ window: String) -> [QuotaBar] {
        zip(range.keys, stats.records).compactMap { key, record in
            guard let quota = record?.quota[window] else { return nil }
            return QuotaBar(key: key, window: window, peak: quota.peak, endOfDay: quota.endOfDay)
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

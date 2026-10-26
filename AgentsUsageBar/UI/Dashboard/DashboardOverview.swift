import Foundation

/// The one range picker shared by Overview and provider detail (SPEC V52). Calendar ignores
/// it and shows every retained day.
public enum DashboardRange: String, CaseIterable, Identifiable, Sendable {
    case days7, days14, days30, days90, thisMonth

    public var id: Self { self }

    var title: String {
        switch self {
        case .days7: return "7 days"
        case .days14: return "14 days"
        case .days30: return "30 days"
        case .days90: return "90 days"
        case .thisMonth: return "This month"
        }
    }

    /// The day keys covered, ending at `today` (the open day). This month starts on the 1st
    /// of `today`'s month, taken from the key text, never a calendar (V2, V40).
    func statsRange(today: String) -> StatsRange {
        let days: Int
        switch self {
        case .days7: days = 7
        case .days14: days = 14
        case .days30: days = 30
        case .days90: days = 90
        case .thisMonth: days = Int(today.suffix(2)) ?? 1
        }
        let resolved = StatsRange.resolve(today: today, days: days, since: nil, until: nil)
        return (try? resolved.get()) ?? StatsRange(keys: [today], today: today)
    }
}

/// Quota band of one day's peak, the strip colours (V53): under 80%, 80%, 95%, 100%.
enum DashboardQuotaCell: Equatable {
    case band(ThresholdBand)
    /// No record that day (V56).
    case gap
    /// A record without this window, such as a backfilled day (V64): no value, not a gap.
    case noValue

    static func band(peak: Double) -> ThresholdBand {
        if peak >= 1 { return .exceeded }
        if peak >= 0.95 { return .critical }
        if peak >= 0.8 { return .warning }
        return .normal
    }
}

/// What the Overview shows for a range and chip selection (V53). Local runtimes are left
/// out: they have presence only and are never drawn as $0 (V56). Split accounts breaks
/// spend per day, the quota strip, and tokens per day into accounts (V68).
struct DashboardOverview {
    typealias Part = DashboardProviderDetail.Part

    struct DayAmount: Identifiable, Equatable {
        let key: String
        let provider: ProviderID
        /// With split on, the account the amount belongs to, or the rest (V68).
        var part: Part = .whole
        let amount: Double
        let estimated: Bool
        let backfilled: Bool
        var id: String { "\(key) \(provider.rawValue) \(part)" }
    }

    struct QuotaRow: Identifiable, Equatable {
        let provider: ProviderID
        /// With split on, the account the row belongs to (V68).
        var account: DayAccount?
        let window: String
        let cells: [DashboardQuotaCell]
        var id: String { "\(provider.rawValue) \(account?.key ?? "") \(window)" }
    }

    let range: StatsRange
    /// Non-local providers with a record in range and selected by the chips, in provider order.
    let providers: [ProviderStats]
    /// Usage events in range for the selected providers. Total-budget events have no
    /// provider and always show.
    let events: [UsageEvent]
    /// With split on, the accounts of each provider with more than one in range, in
    /// first-seen order with newest labels (V22, V68). Other providers stay whole.
    let splitAccounts: [ProviderID: [DayAccount]]

    init(days: [DayFile], range: StatsRange, excluded: Set<ProviderID> = [], order: [ProviderID] = [], split: Bool = false) {
        self.range = range
        providers = ProviderStats.collect(days, range: range, includeLocal: false, order: order)
            .filter { !excluded.contains($0.id) }
        splitAccounts = split ? providers.reduce(into: [:]) { result, p in
            let accounts = DashboardProviderDetail.newestAccounts(p.records)
            if accounts.count > 1 { result[p.id] = accounts }
        } : [:]
        let keys = Set(range.keys)
        events = days.filter { keys.contains($0.date) }.flatMap(\.events)
            .filter { $0.provider.map { !excluded.contains($0) } ?? true }
            .sorted { $0.time < $1.time }
    }

    /// Providers whose spend counts: cost-reporting providers with a metered account in range,
    /// the same set month spend and budgets sum (V26, V40).
    var spendProviders: [ProviderStats] {
        providers.filter { p in
            BudgetScope.providers.contains(p.id) && p.records.contains { $0?.costSplit.hasMetered == true }
        }
    }

    /// Providers with a subscription account in range, whose token-priced cost is value.
    var valueProviders: [ProviderStats] {
        providers.filter { p in p.records.contains { $0?.costSplit.hasSubscription == true } }
    }

    /// Metered spend in range. With This month and every chip on it equals month spend (V53).
    var spend: SpendTotal {
        spendProviders.reduce(into: SpendTotal()) { $0.add($1.spend) }
    }

    /// API-equivalent value, never added to `spend` (V26). Nil hides the tile.
    var value: SpendTotal? {
        let providers = valueProviders
        guard !providers.isEmpty else { return nil }
        return providers.reduce(into: SpendTotal()) { $0.add($1.value) }
    }

    /// Known tokens in range, nil when no provider reports them.
    var tokens: Int? {
        let known = providers.compactMap(\.tokens)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    var notNotifiedCount: Int { events.count { !$0.notified } }

    /// Metered spend per day per provider, for the stacked chart. A day without a known
    /// amount draws nothing: a gap shows in `spendGapKeys`, an unknown amount stays empty.
    /// A split provider has one amount per metered account part (V68).
    var spendPerDay: [DayAmount] {
        spendProviders.flatMap { p in
            zip(range.keys, p.records).flatMap { key, record -> [DayAmount] in
                guard let record else { return [] }
                let parts: [(Part, Money)]
                if splitAccounts[p.id] != nil {
                    parts = record.costSegments.filter { $0.billingModel == .metered }
                        .map { ($0.account.map(Part.account) ?? .unattributed, $0.amount) }
                } else {
                    parts = record.costSplit.spend.map { [(.whole, $0)] } ?? []
                }
                return parts.map { part, spend in
                    DayAmount(
                        key: key, provider: p.id, part: part, amount: NSDecimalNumber(decimal: spend.amount).doubleValue,
                        estimated: record.costEstimated, backfilled: record.origin == .backfilled)
                }
            }
        }
    }

    /// The chart series an amount belongs to: the provider, or with split on, the provider
    /// and the account's newest label (V68).
    func seriesName(_ provider: ProviderID, _ part: Part) -> String {
        switch part {
        case .whole: return provider.displayHint
        case .unattributed: return "\(provider.displayHint) · unattributed"
        case .account(let key):
            let label = splitAccounts[provider]?.first { $0.key == key }?.label ?? key
            return "\(provider.displayHint) · \(label)"
        }
    }

    /// Days where a charted spend provider has no record: grey "no data" bands (V56).
    var spendGapKeys: [String] {
        let providers = spendProviders
        return range.keys.indices.filter { i in providers.contains { $0.records[i] == nil } }.map { range.keys[$0] }
    }

    /// Known tokens per day per provider; a split provider has one amount per account part (V68).
    var tokensPerDay: [DayAmount] {
        providers.flatMap { p in
            zip(range.keys, p.records).flatMap { key, record -> [DayAmount] in
                guard let record else { return [] }
                let parts: [(Part, Int)] = splitAccounts[p.id] != nil
                    ? record.tokenSegments.map { ($0.account.map(Part.account) ?? .unattributed, $0.tokens) }
                    : record.tokens.map { [(.whole, $0)] } ?? []
                return parts.map { part, tokens in
                    DayAmount(
                        key: key, provider: p.id, part: part, amount: Double(tokens),
                        estimated: false, backfilled: record.origin == .backfilled)
                }
            }
        }
    }

    /// Days where a provider reporting tokens in range has no record.
    var tokenGapKeys: [String] {
        let providers = self.providers.filter { $0.tokens != nil }
        return range.keys.indices.filter { i in providers.contains { $0.records[i] == nil } }.map { range.keys[$0] }
    }

    /// One row per provider window seen in range, one cell per day (V53). A split provider
    /// has one row per account window; a day the account was not seen is a gap (V68).
    var quotaRows: [QuotaRow] {
        providers.flatMap { p -> [QuotaRow] in
            guard let accounts = splitAccounts[p.id] else { return Self.quotaRows(p.id, nil, p.records) }
            return accounts.flatMap { account in
                Self.quotaRows(p.id, account, p.records.map { $0.flatMap { DashboardProviderDetail.narrow($0, to: account.key) } })
            }
        }
    }

    private static func quotaRows(_ provider: ProviderID, _ account: DayAccount?, _ records: [DayRecord?]) -> [QuotaRow] {
        let windows = Set(records.compactMap { $0 }.flatMap(\.quota.keys)).sorted()
        return windows.map { window in
            QuotaRow(provider: provider, account: account, window: window, cells: records.map { record in
                guard let record else { return .gap }
                guard let quota = record.quota[window] else { return .noValue }
                return .band(DashboardQuotaCell.band(peak: quota.peak))
            })
        }
    }
}

/// One month budget: its month spend, open day included, against its cap (V40, V53).
struct DashboardBudget: Identifiable, Equatable {
    let scope: BudgetScope
    let spend: SpendTotal
    let cap: Money

    var id: String { scope.name }

    var fraction: Double {
        guard cap.amount > 0 else { return 0 }
        return NSDecimalNumber(decimal: (spend.amount ?? 0) / cap.amount).doubleValue
    }

    /// Every capped scope, total first.
    static func all(days: [DayFile], today: String, budgets: BudgetConfig) -> [DashboardBudget] {
        BudgetScope.all.compactMap { scope in
            budgets.caps[scope].map {
                DashboardBudget(scope: scope, spend: .month(days, today: today, scope: scope), cap: $0)
            }
        }
    }
}

/// The sidebar's provider rows (V52): a 14-day mini chart by the `aub stats` trend rule
/// (V43), and local runtimes apart in "No cost data" with a days-seen strip.
struct DashboardSidebar {
    static let miniChartDays = 14

    /// Non-local providers with a record in any retained day, in provider order.
    let providers: [ProviderStats]
    let localRuntimes: [ProviderStats]

    init(days: [DayFile], today: String, order: [ProviderID] = []) {
        let range = DashboardRange.days14.statsRange(today: today)
        let byKey = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(days.flatMap { $0.records.map(\.provider) })
        let stats = ProviderID.ordered(Array(ids), id: { $0 }, preference: order).map { id in
            ProviderStats(id: id, records: range.keys.map { key in byKey[key]?.records.first { $0.provider == id } })
        }
        providers = stats.filter { $0.kind != .local }
        localRuntimes = stats.filter { $0.kind == .local }
    }
}

extension DashboardRange {
    /// A day key as a date at local midnight, for chart axes. Keys are Gregorian (V2);
    /// labels follow the system calendar.
    static func date(forKey key: String) -> Date {
        keyParser.date(from: key) ?? .distantPast
    }

    private static let keyParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension StatsRange {
    /// The x domain of a day chart: local midnight of the first key to the end of the last.
    var chartDomain: ClosedRange<Date> {
        let first = DashboardRange.date(forKey: keys[0])
        let last = DashboardRange.date(forKey: keys[keys.count - 1])
        return first...last.addingTimeInterval(86_400)
    }
}

import Foundation

/// The one range picker shared by Overview and provider detail (SPEC V52). Calendar ignores
/// it and shows every retained day.
enum DashboardRange: String, CaseIterable, Identifiable, Sendable {
    case days7, days14, days30, days90, thisMonth

    var id: Self { self }

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
/// out: they have presence only and are never drawn as $0 (V56).
struct DashboardOverview {
    struct DayAmount: Identifiable, Equatable {
        let key: String
        let provider: ProviderID
        let amount: Double
        let estimated: Bool
        let backfilled: Bool
        var id: String { "\(key) \(provider.rawValue)" }
    }

    struct QuotaRow: Identifiable, Equatable {
        let provider: ProviderID
        let window: String
        let cells: [DashboardQuotaCell]
        var id: String { "\(provider.rawValue) \(window)" }
    }

    let range: StatsRange
    /// Non-local providers with a record in range and selected by the chips, in provider order.
    let providers: [ProviderStats]
    /// Usage events in range for the selected providers. Total-budget events have no
    /// provider and always show.
    let events: [UsageEvent]

    init(days: [DayFile], range: StatsRange, excluded: Set<ProviderID> = [], order: [ProviderID] = []) {
        self.range = range
        providers = ProviderStats.collect(days, range: range, includeLocal: false, order: order)
            .filter { !excluded.contains($0.id) }
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
    var spendPerDay: [DayAmount] {
        spendProviders.flatMap { p in
            zip(range.keys, p.records).compactMap { key, record in
                guard let record, let spend = record.costSplit.spend else { return nil }
                return DayAmount(
                    key: key, provider: p.id, amount: NSDecimalNumber(decimal: spend.amount).doubleValue,
                    estimated: record.costEstimated, backfilled: record.origin == .backfilled)
            }
        }
    }

    /// Days where a charted spend provider has no record: grey "no data" bands (V56).
    var spendGapKeys: [String] {
        let providers = spendProviders
        return range.keys.indices.filter { i in providers.contains { $0.records[i] == nil } }.map { range.keys[$0] }
    }

    /// Known tokens per day per provider.
    var tokensPerDay: [DayAmount] {
        providers.flatMap { p in
            zip(range.keys, p.records).compactMap { key, record in
                guard let record, let tokens = record.tokens else { return nil }
                return DayAmount(
                    key: key, provider: p.id, amount: Double(tokens),
                    estimated: false, backfilled: record.origin == .backfilled)
            }
        }
    }

    /// Days where a provider reporting tokens in range has no record.
    var tokenGapKeys: [String] {
        let providers = self.providers.filter { $0.tokens != nil }
        return range.keys.indices.filter { i in providers.contains { $0.records[i] == nil } }.map { range.keys[$0] }
    }

    /// One row per provider window seen in range, one cell per day (V53).
    var quotaRows: [QuotaRow] {
        providers.flatMap { p in
            let windows = Set(p.records.compactMap { $0 }.flatMap(\.quota.keys)).sorted()
            return windows.map { window in
                QuotaRow(provider: p.id, window: window, cells: p.records.map { record in
                    guard let record else { return .gap }
                    guard let quota = record.quota[window] else { return .noValue }
                    return .band(DashboardQuotaCell.band(peak: quota.peak))
                })
            }
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

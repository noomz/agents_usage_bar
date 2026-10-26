import Foundation

/// What Calendar shows (SPEC V55): month grids for every retained month, newest first, with
/// days coloured by one metric, and the selected day's panel. Budget rings come from
/// `DashboardBudget`. Grid math and cell keys use Gregorian day keys (V2); only labels
/// follow the system calendar. Chips filter the grids, not the day panel (V53).
struct DashboardCalendar {
    enum Metric: String, CaseIterable, Identifiable, Sendable {
        case spend = "Spend"
        case value = "Value"
        case quotaPeak = "Quota peak"

        var id: Self { self }
    }

    struct Day: Identifiable, Equatable {
        let key: String
        let dayOfMonth: Int
        /// From the oldest retained day to today. Other cells are inert.
        let retained: Bool
        let isToday: Bool
        /// Spend or value of the selected providers, nil when none is known. Spend and
        /// value are separate metrics, never summed (V26).
        let amount: Decimal?
        let estimated: Bool
        /// The selected providers' highest window peak.
        let peak: Double?
        let hasEvent: Bool
        /// A selected provider has no record, or the day has no file: a dashed border (V56).
        let partial: Bool
        var id: String { key }
    }

    struct Month: Identifiable, Equatable {
        /// `yyyy-MM`.
        let key: String
        /// Blank cells before the 1st, for the locale's first weekday.
        let leadingBlanks: Int
        let days: [Day]
        /// A retained day is partial, or retention starts after the 1st (V56).
        let incomplete: Bool
        var id: String { key }
    }

    /// One provider on the selected day. A nil record is a gap (V56).
    struct Card: Identifiable {
        let provider: ProviderID
        let kind: ProviderStats.Kind
        let record: DayRecord?
        let events: [UsageEvent]
        var id: ProviderID { provider }
    }

    struct Panel {
        let key: String
        let isToday: Bool
        let cards: [Card]
        /// Total-budget events, which have no provider.
        let budgetEvents: [UsageEvent]
    }

    let today: String
    let metric: Metric
    let months: [Month]
    /// Providers the chips can switch off: every non-local provider in retained history.
    let chipProviders: [ProviderID]

    private let byKey: [String: DayFile]
    /// Every provider in retained history, in provider order.
    private let providers: [ProviderID]
    private let kinds: [ProviderID: ProviderStats.Kind]
    /// Each provider's oldest day with a record; earlier days are not its gaps.
    private let firstKeys: [ProviderID: String]

    init(
        days: [DayFile],
        today: String,
        metric: Metric = .spend,
        excluded: Set<ProviderID> = [],
        order: [ProviderID] = [],
        firstWeekday: Int = Calendar.current.firstWeekday
    ) {
        self.today = today
        self.metric = metric
        let byKey = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        self.byKey = byKey
        let keys = days.map(\.date).sorted()
        var firstSeen: [ProviderID: String] = [:]
        for key in keys {
            for record in byKey[key]?.records ?? [] where firstSeen[record.provider] == nil {
                firstSeen[record.provider] = key
            }
        }
        let firstKeys = firstSeen
        self.firstKeys = firstKeys
        let providers = ProviderID.ordered(Array(firstKeys.keys), id: { $0 }, preference: order)
        self.providers = providers
        let kinds = Dictionary(uniqueKeysWithValues: providers.map { id in
            (id, ProviderStats(id: id, records: keys.map { key in byKey[key]?.records.first { $0.provider == id } }).kind)
        })
        self.kinds = kinds
        chipProviders = providers.filter { kinds[$0] != .local }

        guard let oldest = keys.first, oldest <= today else {
            months = []
            return
        }
        let selected = chipProviders.filter { !excluded.contains($0) }
        var months: [Month] = []
        var month = Self.monthKey(today)
        while month >= Self.monthKey(oldest) {
            months.append(Self.month(month, oldest: oldest, firstWeekday: firstWeekday) { key in
                Self.day(key, metric: metric, file: byKey[key], selected: selected, firstKeys: firstKeys,
                         excluded: excluded, retained: key >= oldest && key <= today, isToday: key == today)
            })
            month = Self.previousMonth(month)
        }
        self.months = months
    }

    /// The top of the colour scale: the largest retained amount for the metric.
    var top: Decimal {
        months.flatMap(\.days).compactMap(\.amount).max() ?? 0
    }

    /// The day panel, for every provider whatever the chips: a card per provider with a
    /// record, a gap card for one already recording but missing that day, and local
    /// runtimes only on days they ran (V55, V56).
    func panel(_ key: String) -> Panel {
        let file = byKey[key]
        let events = file?.events.sorted { $0.time < $1.time } ?? []
        let cards: [Card] = providers.compactMap { id in
            let record = file?.records.first { $0.provider == id }
            let kind = kinds[id] ?? .metered
            if record == nil {
                guard kind != .local, let first = firstKeys[id], first <= key else { return nil }
            }
            return Card(provider: id, kind: kind, record: record, events: events.filter { $0.provider == id })
        }
        return Panel(key: key, isToday: key == today, cards: cards, budgetEvents: events.filter { $0.provider == nil })
    }

    // MARK: - Cells

    private static func day(
        _ key: String,
        metric: Metric,
        file: DayFile?,
        selected: [ProviderID],
        firstKeys: [ProviderID: String],
        excluded: Set<ProviderID>,
        retained: Bool,
        isToday: Bool
    ) -> Day {
        let records = selected.compactMap { id in file?.records.first { $0.provider == id } }
        var amount: Decimal?
        var estimated = false
        for record in records {
            let split = record.costSplit
            let money: Money?
            switch metric {
            // The cost-reporting providers whose spend month spend and budgets sum (V40).
            case .spend: money = BudgetScope.providers.contains(record.provider) ? split.spend : nil
            case .value: money = split.value
            case .quotaPeak: money = nil
            }
            if let money {
                amount = (amount ?? 0) + money.amount
                estimated = estimated || split.estimated
            }
        }
        let gap = selected.contains { id in
            firstKeys[id].map { $0 <= key } == true && !records.contains { $0.provider == id }
        }
        return Day(
            key: key,
            dayOfMonth: Int(key.suffix(2)) ?? 0,
            retained: retained,
            isToday: isToday,
            amount: amount,
            estimated: estimated,
            peak: records.compactMap { ProviderStats.peak($0)?.fraction }.max(),
            hasEvent: file?.events.contains { $0.provider.map { !excluded.contains($0) } ?? true } == true,
            partial: retained && (file == nil || gap))
    }

    // MARK: - Grid math on day keys (V2)

    private static func month(
        _ key: String, oldest: String, firstWeekday: Int, day: (String) -> Day
    ) -> Month {
        let (year, month) = (Int(key.prefix(4))!, Int(key.suffix(2))!)
        let first = gregorian.date(from: DateComponents(year: year, month: month, day: 1))!
        let count = gregorian.range(of: .day, in: .month, for: first)!.count
        let days = (1...count).map { day("\(key)-" + String(format: "%02d", $0)) }
        return Month(
            key: key,
            leadingBlanks: (gregorian.component(.weekday, from: first) - firstWeekday + 7) % 7,
            days: days,
            incomplete: oldest > "\(key)-01" || days.contains(where: \.partial))
    }

    private static func monthKey(_ dayKey: String) -> String {
        String(dayKey.prefix(7))
    }

    private static func previousMonth(_ key: String) -> String {
        let (year, month) = (Int(key.prefix(4))!, Int(key.suffix(2))!)
        return month == 1 ? String(format: "%04d-12", year - 1) : String(format: "%04d-%02d", year, month - 1)
    }

    /// Day keys are Gregorian calendar dates, so any fixed zone does the arithmetic.
    private static let gregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

import Foundation
import Observation

/// The dashboard window's state (SPEC V20, V52). It decodes every retained day when the
/// window opens, off the MainActor, and holds them only while the window is open: the
/// window controller releases it on close. After a poll only the open day's file is re-read.
@Observable
@MainActor
final class DashboardModel {
    enum Section: Hashable {
        case overview
        case provider(ProviderID)
        case calendar
    }

    var section: Section
    /// Shared by Overview and provider detail (V52).
    var range: DashboardRange = .days14
    /// Providers switched off by the chips, shared by Overview and the Calendar heatmap (V53).
    var excluded: Set<ProviderID> = []
    /// Calendar's selected day; nil is today.
    var selectedDay: String?
    var calendarMetric: DashboardCalendar.Metric = .spend

    private(set) var days: [DayFile] = []
    private(set) var today: String
    /// False until the first load finishes.
    private(set) var isLoaded = false
    private(set) var loadError: String?

    private let reader: HistoryReader
    private let dayKeys: DayKeyOwner
    let order: [ProviderID]

    init(route: DashboardRoute, reader: HistoryReader, dayKeys: DayKeyOwner, order: [ProviderID]) {
        self.reader = reader
        self.dayKeys = dayKeys
        self.order = order
        today = dayKeys.today()
        section = .overview
        show(route)
    }

    /// Selects the view a route names (V51). It only shows a view and changes nothing.
    func show(_ route: DashboardRoute) {
        switch route.destination {
        case .overview:
            section = .overview
        case .provider(let id):
            section = .provider(id)
        case .calendar(let day, _):
            section = .calendar
            selectedDay = day
        }
    }

    /// Reads every retained day file.
    func load() async {
        today = dayKeys.today()
        do {
            days = try await reader.days()
            loadError = nil
        } catch {
            loadError = "Cannot read usage history: \(error.localizedDescription)"
        }
        isLoaded = true
    }

    /// After a poll, re-reads only the open day's file (V20). A new day key means the
    /// previous day was sealed, so everything is read again.
    func reloadOpenDay() async {
        guard isLoaded else { return }
        guard dayKeys.today() == today else { return await load() }
        let key = today
        let day = await reader.day(key)
        days.removeAll { $0.date == key }
        if let day { days.append(day) }
    }

    var overview: DashboardOverview {
        DashboardOverview(days: days, range: range.statsRange(today: today), excluded: excluded, order: order)
    }

    /// Every retained day, whatever the range (V52).
    var calendar: DashboardCalendar {
        DashboardCalendar(days: days, today: today, metric: calendarMetric, excluded: excluded, order: order)
    }

    var sidebar: DashboardSidebar {
        DashboardSidebar(days: days, today: today, order: order)
    }

    func budgets(_ config: BudgetConfig) -> [DashboardBudget] {
        DashboardBudget.all(days: days, today: today, budgets: config)
    }

    /// What Export… covers (V57): Overview its range and chips, provider detail that provider
    /// and range, Calendar every retained day.
    func exportScope(isEnabled: @escaping @Sendable (ProviderID) -> Bool) -> HistoryExportRenderer.Scope {
        let range = self.range.statsRange(today: today)
        switch section {
        case .overview:
            return .init(range: range, excluded: excluded, isEnabled: isEnabled)
        case .provider(let id):
            return .init(range: range, provider: id, isEnabled: isEnabled)
        case .calendar:
            let oldest = days.map(\.date).min()
            let all = (try? StatsRange.resolve(today: today, days: nil, since: nil, until: nil, oldest: oldest).get())
                ?? StatsRange(keys: [today], today: today)
            return .init(range: all, isEnabled: isEnabled)
        }
    }

    /// Renders the held days with the `aub stats` renderer, so the bytes match the CLI for
    /// the same scope (V47). Reads nothing (V20).
    func export(
        _ format: DashboardExportFormat,
        isEnabled: @escaping @Sendable (ProviderID) -> Bool,
        exportedAt: Date
    ) throws -> String {
        let scope = exportScope(isEnabled: isEnabled)
        switch format {
        case .json:
            return try HistoryExportRenderer.json(days, scope: scope, exportedAt: exportedAt)
        case .csv(let table):
            return HistoryExportRenderer.csv(days, scope: scope, table: table)
        }
    }

    func toggle(_ provider: ProviderID) {
        if excluded.contains(provider) {
            excluded.remove(provider)
        } else {
            excluded.insert(provider)
        }
    }
}

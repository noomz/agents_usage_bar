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

    func toggle(_ provider: ProviderID) {
        if excluded.contains(provider) {
            excluded.remove(provider)
        } else {
            excluded.insert(provider)
        }
    }
}

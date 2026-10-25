import SwiftUI

/// Root of the dashboard window. S6 fills in the sidebar, Overview, provider detail, and
/// Calendar (SPEC V52–V55); this shell names the view the route selects.
struct DashboardRootView: View {
    let route: DashboardRoute

    var body: some View {
        Text(heading)
            .font(.title2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var heading: String {
        switch route.destination {
        case .overview: return "Overview"
        case .provider(let id): return id.rawValue
        case .calendar(let day, _): return "Calendar · \(day)"
        }
    }
}

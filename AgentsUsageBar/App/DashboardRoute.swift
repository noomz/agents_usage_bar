import AppKit
import Foundation

/// What a dashboard URL asks to show (SPEC V51): `agentsusagebar://dashboard[?day=yyyy-MM-dd&provider=<id>]`.
/// Every entry point opens this URL. It only shows a view and changes nothing.
public struct DashboardRoute: Equatable, Sendable {
    public static let scheme = "agentsusagebar"
    static let host = "dashboard"

    public var day: String?
    public var provider: ProviderID?

    public init(day: String? = nil, provider: ProviderID? = nil) {
        self.day = day
        self.provider = provider
    }

    /// The route a URL names, or nil when it is not a dashboard URL. Invalid or unknown
    /// parameters are dropped, so the URL still opens the dashboard.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.host else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        day = value("day").flatMap { StatsRange.isDayKey($0) ? $0 : nil }
        provider = value("provider").flatMap(ProviderID.named)
    }

    /// The dashboard view a route selects (V58): a day opens Calendar on that day with the
    /// provider's card outlined, a provider alone opens its detail, nothing opens Overview.
    public enum Destination: Equatable, Sendable {
        case overview
        case provider(ProviderID)
        case calendar(day: String, provider: ProviderID?)
    }

    public var destination: Destination {
        if let day { return .calendar(day: day, provider: provider) }
        if let provider { return .provider(provider) }
        return .overview
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        var items: [URLQueryItem] = []
        if let day { items.append(URLQueryItem(name: "day", value: day)) }
        if let provider { items.append(URLQueryItem(name: "provider", value: provider.rawValue)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    /// Opens the route's URL in this app bundle, launching it if needed. Targets the bundle
    /// that holds this binary so a second installed copy never answers the scheme.
    public func open() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
    }
}

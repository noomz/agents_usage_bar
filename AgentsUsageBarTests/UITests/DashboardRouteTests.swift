import Foundation
import Testing
@testable import AgentsUsageBar

/// SPEC V51 — every dashboard entry point opens `agentsusagebar://dashboard[?day&provider]`.
@Suite("DashboardRoute")
struct DashboardRouteTests {

    private func route(_ string: String) -> DashboardRoute? {
        DashboardRoute(url: URL(string: string)!)
    }

    @Test("bare URL opens Overview")
    func bare() {
        #expect(route("agentsusagebar://dashboard") == DashboardRoute())
        #expect(DashboardRoute().destination == .overview)
    }

    @Test("day and provider parse; a day selects Calendar with the provider outlined")
    func dayAndProvider() {
        let r = route("agentsusagebar://dashboard?day=2026-10-24&provider=claude")
        #expect(r == DashboardRoute(day: "2026-10-24", provider: .claude))
        #expect(r?.destination == .calendar(day: "2026-10-24", provider: .claude))
    }

    @Test("provider alone selects its detail; engine ids are accepted")
    func providerOnly() {
        #expect(route("agentsusagebar://dashboard?provider=codex")?.destination == .provider(.codex))
        #expect(route("agentsusagebar://dashboard?provider=engine.vllm")?.provider == ProviderID(rawValue: "engine.vllm"))
    }

    @Test("invalid or unknown parameters are ignored, the URL still opens the dashboard")
    func invalidParametersIgnored() {
        #expect(route("agentsusagebar://dashboard?day=2026-02-30&provider=nope") == DashboardRoute())
        #expect(route("agentsusagebar://dashboard?day=yesterday&provider=gemini") == DashboardRoute(provider: .gemini))
        #expect(route("agentsusagebar://dashboard?day=2026-10-24&extra=1") == DashboardRoute(day: "2026-10-24"))
        #expect(route("agentsusagebar://dashboard?day=") == DashboardRoute())
    }

    @Test("range, event, and window parse; unknown values are dropped (V51)")
    func rangeEventWindow() {
        let r = route("agentsusagebar://dashboard?day=2026-10-24&provider=claude&event=pace&window=5h")
        #expect(r == DashboardRoute(day: "2026-10-24", provider: .claude, event: .pace, window: "5h"))
        #expect(route("agentsusagebar://dashboard?range=thisMonth") == DashboardRoute(range: .thisMonth))
        #expect(route("agentsusagebar://dashboard?range=forever&event=boom&window=") == DashboardRoute())
    }

    @Test("other schemes and hosts are not dashboard URLs")
    func notDashboard() {
        #expect(route("agentsusagebar://settings") == nil)
        #expect(route("https://dashboard?day=2026-10-24") == nil)
    }

    @Test("url round-trips through init(url:)")
    func roundTrip() {
        for r in [
            DashboardRoute(), DashboardRoute(provider: .openrouter), DashboardRoute(day: "2026-10-01", provider: .claude),
            DashboardRoute(range: .days14),
            DashboardRoute(day: "2026-10-01", provider: .codex, event: .reset, window: "7d sonnet"),
        ] {
            #expect(DashboardRoute(url: r.url) == r)
        }
        #expect(DashboardRoute().url.absoluteString == "agentsusagebar://dashboard")
        #expect(DashboardRoute(day: "2026-10-01", provider: .claude).url.absoluteString
                == "agentsusagebar://dashboard?day=2026-10-01&provider=claude")
    }

    @Test("Info.plist registers the agentsusagebar URL scheme")
    func infoPlistRegistersScheme() {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains(DashboardRoute.scheme))
    }
}

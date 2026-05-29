import Testing
import Foundation
import UserNotifications
@testable import AgentsUsageBar

/// Plan 02.05 — covers categoryIdentifier on every scheduled request + 3-band coalesced IDs.
@Suite("NotificationManagerCategoryTests")
struct NotificationManagerCategoryTests {

    // MARK: - Fixtures (mirror NotificationManagerTests)

    static let noon_2026_05_13_PT: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 13
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "America/Los_Angeles")
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return cal.date(from: comps)!
    }()

    static let ptCalendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    static let pidA = ProviderID(rawValue: "openrouter")
    static let pidB = ProviderID(rawValue: "claude")

    func makeDecision(
        pid: ProviderID = NotificationManagerCategoryTests.pidA,
        displayName: String = "OpenRouter",
        band: ThresholdBand = .warning,
        suffix: String = "warn80"
    ) -> NotificationDecision {
        NotificationDecision(
            id: "\(pid.rawValue):2026-05-13:\(suffix)",
            title: "\(displayName) at 80%",
            body: "$8.00 of $10.00 used today.",
            providerID: pid,
            displayName: displayName,
            band: band
        )
    }

    func makeManager(_ center: FakeUNUserNotificationCenter) -> UNNotificationManager {
        UNNotificationManager(
            center: center,
            clock: VirtualClock(fixed: Self.noon_2026_05_13_PT),
            calendar: Self.ptCalendar
        )
    }

    // MARK: - categoryIdentifier on every request

    @Test("schedule single decision sets categoryIdentifier == 'usage.warning' (Pitfall 6)")
    func schedule_singleDecision_setsCategoryIdentifier() async throws {
        let center = FakeUNUserNotificationCenter()
        let manager = makeManager(center)
        await manager.schedule([makeDecision()])
        let req = try #require(center.addCalls.first)
        #expect(req.content.categoryIdentifier == "usage.warning")
        #expect(req.content.categoryIdentifier == UNNotificationManager.usageWarningCategoryID)
    }

    @Test("schedule coalesced (2 decisions) sets categoryIdentifier on the coalesced request")
    func schedule_coalesced_setsCategoryIdentifier() async throws {
        let center = FakeUNUserNotificationCenter()
        let manager = makeManager(center)
        let d1 = makeDecision()
        let d2 = makeDecision(pid: Self.pidB, displayName: "Claude")
        await manager.schedule([d1, d2])
        #expect(center.addCalls.count == 1)
        let req = try #require(center.addCalls.first)
        #expect(req.content.categoryIdentifier == "usage.warning")
    }

    // MARK: - Coalesced ID highest-band suffix (NOTIF-03 extension)

    @Test("coalesced ID uses :warn80 when all decisions are .warning")
    func coalesced_id_uses_highestBand_suffix_warning() async throws {
        let center = FakeUNUserNotificationCenter()
        let manager = makeManager(center)
        let d1 = makeDecision(band: .warning, suffix: "warn80")
        let d2 = makeDecision(pid: Self.pidB, displayName: "Claude", band: .warning, suffix: "warn80")
        await manager.schedule([d1, d2])
        let req = try #require(center.addCalls.first)
        #expect(req.identifier == "coalesced:2026-05-13:warn80")
    }

    @Test("coalesced ID uses :crit95 when mixed .warning + .critical")
    func coalesced_id_uses_highestBand_suffix_critical() async throws {
        let center = FakeUNUserNotificationCenter()
        let manager = makeManager(center)
        let d1 = makeDecision(band: .warning, suffix: "warn80")
        let d2 = makeDecision(pid: Self.pidB, displayName: "Claude", band: .critical, suffix: "crit95")
        await manager.schedule([d1, d2])
        let req = try #require(center.addCalls.first)
        #expect(req.identifier == "coalesced:2026-05-13:crit95")
    }

    @Test("coalesced ID uses :exceed100 when any decision is .exceeded")
    func coalesced_id_uses_highestBand_suffix_exceeded() async throws {
        let center = FakeUNUserNotificationCenter()
        let manager = makeManager(center)
        let d1 = makeDecision(band: .critical, suffix: "crit95")
        let d2 = makeDecision(pid: Self.pidB, displayName: "Claude", band: .exceeded, suffix: "exceed100")
        await manager.schedule([d1, d2])
        let req = try #require(center.addCalls.first)
        #expect(req.identifier == "coalesced:2026-05-13:exceed100")
    }

    // MARK: - Coalesced title reflects highest-band percent

    @Test("coalesced title says 'N providers crossed 95%' when highest band is .critical")
    func coalesced_title_reflects_highestBand_percent() async throws {
        let center = FakeUNUserNotificationCenter()
        let manager = makeManager(center)
        let d1 = makeDecision(band: .warning, suffix: "warn80")
        let d2 = makeDecision(pid: Self.pidB, displayName: "Claude", band: .critical, suffix: "crit95")
        await manager.schedule([d1, d2])
        let req = try #require(center.addCalls.first)
        #expect(req.content.title == "2 providers crossed 95%")
    }

    @Test("coalesced title says 'N providers crossed 100%' when highest band is .exceeded")
    func coalesced_title_reflects_exceeded_percent() async throws {
        let center = FakeUNUserNotificationCenter()
        let manager = makeManager(center)
        let d1 = makeDecision(band: .warning, suffix: "warn80")
        let d2 = makeDecision(pid: Self.pidB, displayName: "Claude", band: .exceeded, suffix: "exceed100")
        let d3 = makeDecision(
            pid: ProviderID(rawValue: "codex"),
            displayName: "Codex",
            band: .critical,
            suffix: "crit95"
        )
        await manager.schedule([d1, d2, d3])
        let req = try #require(center.addCalls.first)
        #expect(req.content.title == "3 providers crossed 100%")
    }
}

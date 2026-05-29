import Testing
import Foundation
import UserNotifications
@testable import AgentsUsageBar

// MARK: - FakeUNUserNotificationCenter

/// Test double capturing `requestAuthorization` and `add(_:)` calls.
/// `@unchecked Sendable` because mutation is caller-serialized via Swift Testing's
/// structured concurrency (each `@Test` async func runs independently).
final class FakeUNUserNotificationCenter: UNUserNotificationCenterProtocol, @unchecked Sendable {
    var grantAuthorization: Bool = true
    var requestAuthorizationCallCount: Int = 0
    var addCalls: [UNNotificationRequest] = []
    var shouldThrowOnAdd: Bool = false

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestAuthorizationCallCount += 1
        return grantAuthorization
    }

    func add(_ request: UNNotificationRequest) async throws {
        if shouldThrowOnAdd { throw NSError(domain: "test", code: 1) }
        addCalls.append(request)
    }
}

// MARK: - Helper factory

extension FakeUNUserNotificationCenter {
    func makeManager(
        clock: any Clock = SystemClock(),
        calendar: Calendar = .current
    ) -> UNNotificationManager {
        UNNotificationManager(center: self, clock: clock, calendar: calendar)
    }
}

// MARK: - Fixed date helpers

private enum FixedDates {
    /// 2026-05-11 12:00:00 America/Los_Angeles
    static var noon_2026_05_11_PT: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 11
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "America/Los_Angeles")
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return cal.date(from: comps)!
    }

    static var ptCalendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }
}

// MARK: - Helper decision builders

private func makeDecision(
    id: String = "openrouter:2026-05-11:warn80",
    title: String = "OpenRouter at 82%",
    body: String = "$8.20 of $10.00 used today.",
    providerID: ProviderID = .openrouter,
    displayName: String = "OpenRouter",
    band: ThresholdBand = .warning
) -> NotificationDecision {
    NotificationDecision(
        id: id,
        title: title,
        body: body,
        providerID: providerID,
        displayName: displayName,
        band: band
    )
}

// MARK: - Tests

@Suite("NotificationManagerTests")
struct NotificationManagerTests {

    @Test("empty decision list → no add() calls AND no auth request")
    func emptyDecisionsNoAuthNoAdd() async {
        let center = FakeUNUserNotificationCenter()
        let manager = center.makeManager()
        await manager.schedule([])
        #expect(center.requestAuthorizationCallCount == 0)
        #expect(center.addCalls.isEmpty)
    }

    @Test("single decision → one add() with provider-specific stable id (D-13 path)")
    func singleDecisionUsesPerProviderID() async throws {
        let center = FakeUNUserNotificationCenter()
        let manager = center.makeManager()
        let d1 = makeDecision()
        await manager.schedule([d1])
        #expect(center.addCalls.count == 1)
        let req = try #require(center.addCalls.first)
        #expect(req.identifier == d1.id)
        #expect(req.content.title == d1.title)
        #expect(req.content.body == d1.body)
    }

    @Test("two decisions → ONE add() with coalesced id and 'N providers crossed 80%' title (B3 + NOTIF-07)")
    func twoDecisionsCoalesceToOneNotification() async throws {
        let center = FakeUNUserNotificationCenter()
        let clock = VirtualClock(fixed: FixedDates.noon_2026_05_11_PT)
        let manager = center.makeManager(clock: clock, calendar: FixedDates.ptCalendar)
        let d1 = makeDecision(
            id: "openrouter:2026-05-11:warn80",
            displayName: "OpenRouter"
        )
        let d2 = makeDecision(
            id: "codex:2026-05-11:warn80",
            title: "Codex at 85%",
            body: "$8.50 of $10.00 used today.",
            providerID: ProviderID(rawValue: "codex"),
            displayName: "Codex"
        )
        await manager.schedule([d1, d2])
        // Exactly ONE add() call (coalesced)
        #expect(center.addCalls.count == 1)
        let req = try #require(center.addCalls.first)
        // Coalesced stable ID uses clock.now() — deterministic via VirtualClock (B8)
        #expect(req.identifier == "coalesced:2026-05-11:warn80")
        #expect(req.content.title == "2 providers crossed 80%")
        #expect(req.content.body == "OpenRouter, Codex")
    }

    @Test("three decisions → ONE add() with title '3 providers crossed 80%' (B8 clock fixed)")
    func threeDecisionsCoalesceToOneWithCorrectCount() async throws {
        let center = FakeUNUserNotificationCenter()
        let clock = VirtualClock(fixed: FixedDates.noon_2026_05_11_PT)
        let manager = center.makeManager(clock: clock, calendar: FixedDates.ptCalendar)
        let d1 = makeDecision(displayName: "OpenRouter")
        let d2 = makeDecision(
            id: "codex:2026-05-11:warn80",
            providerID: ProviderID(rawValue: "codex"),
            displayName: "Codex"
        )
        let d3 = makeDecision(
            id: "gemini:2026-05-11:warn80",
            providerID: ProviderID(rawValue: "gemini"),
            displayName: "Gemini"
        )
        await manager.schedule([d1, d2, d3])
        #expect(center.addCalls.count == 1)
        let req = try #require(center.addCalls.first)
        #expect(req.content.title == "3 providers crossed 80%")
        #expect(req.identifier == "coalesced:2026-05-11:warn80")
    }

    @Test("lazy auth on FIRST schedule call only (NOTIF-06)")
    func lazyAuthOnFirstCallOnly() async {
        let center = FakeUNUserNotificationCenter()
        center.grantAuthorization = true
        let manager = center.makeManager()
        let d1 = makeDecision()
        // First schedule: triggers auth
        await manager.schedule([d1])
        #expect(center.requestAuthorizationCallCount == 1)
        // Second schedule: auth already cached — no second requestAuthorization call
        await manager.schedule([d1])
        #expect(center.requestAuthorizationCallCount == 1)
    }

    @Test("auth denial → silent failure, no add() (D-12)")
    func authDenialSilentlySwallowed() async {
        let center = FakeUNUserNotificationCenter()
        center.grantAuthorization = false
        let manager = center.makeManager()
        let d1 = makeDecision()
        await manager.schedule([d1])
        // Auth denied — no add() calls and no thrown error
        #expect(center.addCalls.isEmpty)
    }

    @Test("auth NOT requested when decisions is empty (NOTIF-06)")
    func authNotRequestedForEmptyDecisions() async {
        let center = FakeUNUserNotificationCenter()
        let manager = center.makeManager()
        await manager.schedule([])
        #expect(center.requestAuthorizationCallCount == 0)
    }

    @Test("coalesced body is deterministic order matching engine order (not sorted)")
    func coalescedBodyPreservesInputOrder() async throws {
        let center = FakeUNUserNotificationCenter()
        let clock = VirtualClock(fixed: FixedDates.noon_2026_05_11_PT)
        let manager = center.makeManager(clock: clock, calendar: FixedDates.ptCalendar)
        // Reversed order: Codex first, OpenRouter second
        let d1 = makeDecision(
            id: "codex:2026-05-11:warn80",
            providerID: ProviderID(rawValue: "codex"),
            displayName: "Codex"
        )
        let d2 = makeDecision(displayName: "OpenRouter")
        await manager.schedule([d1, d2])
        let req = try #require(center.addCalls.first)
        // Body must preserve input order, NOT alphabetical sort
        #expect(req.content.body == "Codex, OpenRouter")
    }
}

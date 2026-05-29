import Testing
import Foundation
@testable import AgentsUsageBar

/// Plan 02.05 — covers `NotificationActionHandler.handle(actionID:identifier:now:)` routing.
///
/// `UNNotificationResponse` is not publicly constructible, so the production code factors
/// the routing logic into a pure `handle(...)` helper that tests exercise directly. The
/// `userNotificationCenter(_:didReceive:withCompletionHandler:)` delegate method is a thin
/// wrapper that extracts the action ID + identifier and calls this helper.
@MainActor
@Suite("NotificationActionHandlerTests")
struct NotificationActionHandlerTests {

    /// Pinned to noon UTC so the date string matches across every reasonable test-host timezone.
    static let now: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 13
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)!
    }()

    /// Derive `today` from `now` using host calendar — matches the production code path.
    static var today: String { TodayHelper.formatYYYYMMDD(now) }
    static let pidA = ProviderID(rawValue: "openrouter")
    static let pidB = ProviderID(rawValue: "claude")

    func makeStore(notificationState: InMemoryNotificationStateStore? = nil) -> (AggregateStore, InMemoryNotificationStateStore) {
        let state = notificationState ?? InMemoryNotificationStateStore()
        let store = AggregateStore(
            registry: [],
            clock: VirtualClock(fixed: Self.now),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager(),
            notificationState: state
        )
        return (store, state)
    }

    // MARK: - Routing

    @Test("snooze.today action with per-provider id calls store.snoozeToday")
    func handle_snoozeAction_perProviderID_callsSnoozeToday() {
        let (store, state) = makeStore()
        let handler = NotificationActionHandler(store: store, clock: VirtualClock(fixed: Self.now))
        handler.handle(
            actionID: UNNotificationManager.snoozeActionID,
            identifier: "openrouter:2026-05-13:warn80",
            now: Self.now
        )
        let record = state.record(forProviderID: Self.pidA, day: Self.today)
        #expect(record?.snoozedUntilDay == Self.today)
    }

    @Test("snooze.today action with coalesced id snoozes ALL seeded providers")
    func handle_snoozeAction_coalesced_snoozesAllProviders() {
        let (store, state) = makeStore()
        // Seed two providers so snoozeAllToday has work to do.
        store.seedPlaceholder(providerID: Self.pidA, displayName: "OpenRouter")
        store.seedPlaceholder(providerID: Self.pidB, displayName: "Claude")
        let handler = NotificationActionHandler(store: store, clock: VirtualClock(fixed: Self.now))
        handler.handle(
            actionID: UNNotificationManager.snoozeActionID,
            identifier: "coalesced:2026-05-13:crit95",
            now: Self.now
        )
        #expect(state.record(forProviderID: Self.pidA, day: Self.today)?.snoozedUntilDay == Self.today)
        #expect(state.record(forProviderID: Self.pidB, day: Self.today)?.snoozedUntilDay == Self.today)
    }

    @Test("unknown action identifier is a no-op")
    func handle_unknownAction_isNoOp() {
        let (store, state) = makeStore()
        let handler = NotificationActionHandler(store: store, clock: VirtualClock(fixed: Self.now))
        handler.handle(
            actionID: "unknown.action",
            identifier: "openrouter:2026-05-13:warn80",
            now: Self.now
        )
        #expect(state.record(forProviderID: Self.pidA, day: Self.today) == nil)
    }

    @Test("malformed identifier with no ':' separator is a no-op")
    func handle_malformedID_isNoOp() {
        let (store, state) = makeStore()
        let handler = NotificationActionHandler(store: store, clock: VirtualClock(fixed: Self.now))
        handler.handle(
            actionID: UNNotificationManager.snoozeActionID,
            identifier: "garbage-no-colons",
            now: Self.now
        )
        // No mutation — and no crash.
        #expect(state.allRecordsForToday(Self.today).isEmpty)
    }
}

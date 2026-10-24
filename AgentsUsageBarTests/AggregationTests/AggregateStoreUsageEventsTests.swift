import Testing
import Foundation
@testable import AgentsUsageBar

/// T18 — band, pace, reset, and auth crossings land in the open day's `events[]` (V33–V38).
@MainActor
@Suite("AggregateStoreUsageEventsTests")
struct AggregateStoreUsageEventsTests {

    private static let utc = TimeZone(identifier: "UTC")!
    private static let pid = ProviderID(rawValue: "openrouter")

    private static func at(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// One poll's outcome: a quota fraction (optionally degraded) or an error.
    enum Outcome: Sendable {
        case fraction(Double, degraded: Bool = false)
        case failure(ProviderError)
    }

    final actor ScriptedProvider: UsageProvider {
        nonisolated let id = ProviderID(rawValue: "openrouter")
        nonisolated let displayName = "OpenRouter"
        nonisolated let capabilities = ProviderCapabilities(
            hasQuota: true, hasCost: true, hasTokens: false, isLocal: false
        )
        private var next: Outcome = .fraction(0)

        func set(_ outcome: Outcome) {
            next = outcome
        }

        func status() -> ProviderStatus { .ok(lastSuccess: Date()) }

        func fetch(now: Date) async throws -> UsageSnapshot {
            switch next {
            case .failure(let error):
                throw error
            case .fraction(let fraction, let degraded):
                return UsageSnapshot(
                    providerID: id,
                    asOf: now,
                    tokensToday: nil,
                    costTodayUSD: nil,
                    balanceUSD: nil,
                    quota: Quota(used: fraction * 100, limit: 100, remaining: 100 - fraction * 100),
                    raw: degraded ? ["note": ThresholdEngine.degradedTag] : [:]
                )
            }
        }
    }

    private struct Harness {
        let provider = ScriptedProvider()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store: AggregateStore

        @MainActor
        init() {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = AggregateStoreUsageEventsTests.utc
            let dayKeys = DayKeyOwner(
                clock: VirtualClock(fixed: AggregateStoreUsageEventsTests.at("2026-10-22T12:00:00Z")),
                timeZone: AggregateStoreUsageEventsTests.utc,
                legacyCalendar: gregorian
            )
            store = AggregateStore(
                registry: [provider],
                clock: VirtualClock(fixed: AggregateStoreUsageEventsTests.at("2026-10-22T12:00:00Z")),
                cache: AggFakeCacheStore(),
                thresholds: ThresholdEngine(dayKeys: dayKeys),
                notifications: NoopNotificationManager(),
                notificationState: InMemoryNotificationStateStore(),
                dayKeys: dayKeys,
                history: HistoryStore(directory: dir, dayKeys: dayKeys)
            )
        }

        func poll(_ outcome: Outcome, at iso: String) async {
            await provider.set(outcome)
            await store.refresh(now: AggregateStoreUsageEventsTests.at(iso))
        }

        func events(_ key: String) async -> [UsageEvent] {
            await HistoryReader(directory: dir).day(key)?.events ?? []
        }
    }

    @Test("a jump across two bands records both crossings, notified, at the poll time (V33, V34, V38)")
    func bandCrossings() async {
        let h = Harness()
        await h.poll(.fraction(0.50), at: "2026-10-22T09:00:00Z")
        #expect(await h.events("2026-10-22").isEmpty)

        await h.poll(.fraction(0.97), at: "2026-10-22T10:00:00Z")
        let events = await h.events("2026-10-22")
        #expect(events.map(\.kind) == [.band80, .band95])
        #expect(events.allSatisfy {
            $0.provider == Self.pid && $0.window == nil && $0.notified && !$0.carriedOver
                && $0.time == Self.at("2026-10-22T10:00:00Z") && $0.fraction == 0.97
        })

        // Same band again: no new event.
        await h.poll(.fraction(0.98), at: "2026-10-22T11:00:00Z")
        #expect(await h.events("2026-10-22").count == 2)
    }

    @Test("a crossing while snoozed is recorded with notified false (V34)")
    func snoozedCrossing() async {
        let h = Harness()
        h.store.snoozeToday(providerID: Self.pid, on: Self.at("2026-10-22T09:00:00Z"))
        await h.poll(.fraction(0.85), at: "2026-10-22T09:00:00Z")
        let events = await h.events("2026-10-22")
        #expect(events.map(\.kind) == [.band80])
        #expect(events.first?.notified == false)
    }

    @Test("still above a band at the first poll of a new day records it carried over (V35)")
    func carriedOver() async {
        let h = Harness()
        await h.poll(.fraction(0.85), at: "2026-10-22T23:50:00Z")
        await h.poll(.fraction(0.86), at: "2026-10-23T00:10:00Z")

        #expect(await h.events("2026-10-22").map(\.carriedOver) == [false])
        let next = await h.events("2026-10-23")
        #expect(next.map(\.kind) == [.band80])
        #expect(next.first?.carriedOver == true)
    }

    @Test("a band crossed again after falling below overnight is not carried over (V35)")
    func recrossedNewDay() async {
        let h = Harness()
        await h.poll(.fraction(0.85), at: "2026-10-22T23:00:00Z")
        await h.poll(.fraction(0.10), at: "2026-10-23T00:10:00Z")
        await h.poll(.fraction(0.90), at: "2026-10-23T09:00:00Z")
        #expect(await h.events("2026-10-23").map(\.carriedOver) == [false])
    }

    @Test("a degraded snapshot records nothing; the next good poll records at its own time (V37)")
    func degraded() async {
        let h = Harness()
        await h.poll(.fraction(0.90, degraded: true), at: "2026-10-22T09:00:00Z")
        #expect(await h.events("2026-10-22").isEmpty)

        await h.poll(.fraction(0.90), at: "2026-10-22T10:00:00Z")
        let events = await h.events("2026-10-22")
        #expect(events.map(\.kind) == [.band80])
        #expect(events.first?.time == Self.at("2026-10-22T10:00:00Z"))
    }

    @Test("ok → auth error is auth lost, network errors say nothing, the next ok is auth recovered (V36)")
    func authLostAndRecovered() async {
        let h = Harness()
        await h.poll(.fraction(0.10), at: "2026-10-22T09:00:00Z")
        await h.poll(.failure(ProviderError(kind: .auth, message: "HTTP 401")), at: "2026-10-22T09:10:00Z")
        await h.poll(.failure(ProviderError(kind: .network, message: "offline")), at: "2026-10-22T09:20:00Z")
        await h.poll(.failure(ProviderError(kind: .paymentRequired, message: "HTTP 402")), at: "2026-10-22T09:30:00Z")
        await h.poll(.fraction(0.10), at: "2026-10-22T09:40:00Z")

        let events = await h.events("2026-10-22")
        #expect(events.map(\.kind) == [.authLost, .authRecovered])
        #expect(events.map(\.time) == [Self.at("2026-10-22T09:10:00Z"), Self.at("2026-10-22T09:40:00Z")])
        #expect(events.allSatisfy { !$0.notified && $0.provider == Self.pid })
    }

    @Test("auth failing on the first poll after launch records no event, nor does the next ok (V36)")
    func noEventAtLaunch() async {
        let h = Harness()
        await h.poll(.failure(ProviderError(kind: .auth, message: "HTTP 401")), at: "2026-10-22T09:00:00Z")
        await h.poll(.fraction(0.10), at: "2026-10-22T09:10:00Z")
        #expect(await h.events("2026-10-22").isEmpty)
    }

    @Test("a network error after ok is not auth lost (V36)")
    func networkErrorNoEvent() async {
        let h = Harness()
        await h.poll(.fraction(0.10), at: "2026-10-22T09:00:00Z")
        await h.poll(.failure(ProviderError(kind: .network, message: "offline")), at: "2026-10-22T09:10:00Z")
        await h.poll(.fraction(0.10), at: "2026-10-22T09:20:00Z")
        #expect(await h.events("2026-10-22").isEmpty)
    }
}

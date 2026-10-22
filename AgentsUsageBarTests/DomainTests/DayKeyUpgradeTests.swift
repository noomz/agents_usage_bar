import Testing
import Foundation
@testable import AgentsUsageBar

/// SPEC V3: the first launch after S0 on a Buddhist-calendar host. `today.json` and
/// notification state hold keys a pre-S0 build wrote with `Calendar.current` (`2569-10-22`);
/// the day key is `2026-10-22`. The upgrade keeps the OpenRouter baseline, the daily
/// accumulator, and the fired bands.
@MainActor
@Suite("DayKeyUpgradeTests")
struct DayKeyUpgradeTests {

    private static let bangkok = TimeZone(identifier: "Asia/Bangkok")!
    /// 2026-10-22 10:00 ICT.
    private static let now = ISO8601DateFormatter().date(from: "2026-10-22T03:00:00Z")!
    private static let dayKey = "2026-10-22"
    private static let legacyKey = "2569-10-22"
    private static let legacyYesterday = "2569-10-21"

    private static func owner() -> DayKeyOwner {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = bangkok
        return DayKeyOwner(clock: VirtualClock(fixed: now), timeZone: bangkok, legacyCalendar: buddhist)
    }

    private static func makeCache() throws -> FileCacheStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try FileCacheStore(testingRootURL: dir, dayKeys: owner())
    }

    /// Rewrites every day key in `today.json` to `stored`, as a pre-S0 build would have written it.
    private static func rewriteDates(in cache: FileCacheStore, to stored: String) throws {
        let url = cache.cacheURLForTesting
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(dayKey))
        try text.replacingOccurrences(of: dayKey, with: stored).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: today.json

    @Test("a legacy same-day OpenRouter baseline is kept, not reset")
    func legacyBaselineKept() throws {
        let cache = try Self.makeCache()
        cache.maintainBaseline(for: .openrouter, now: Self.now, currentValue: 10)
        try Self.rewriteDates(in: cache, to: Self.legacyKey)

        cache.maintainBaseline(for: .openrouter, now: Self.now, currentValue: 12)

        let b = try #require(cache.baseline(for: .openrouter, on: Self.now))
        #expect(b.value == 10)
        #expect(b.lastValue == 12)
        #expect(b.date == Self.dayKey)
    }

    @Test("a legacy key for an earlier day still starts a fresh baseline")
    func legacyYesterdayBaselineResets() throws {
        let cache = try Self.makeCache()
        cache.maintainBaseline(for: .openrouter, now: Self.now, currentValue: 10)
        try Self.rewriteDates(in: cache, to: Self.legacyYesterday)

        cache.maintainBaseline(for: .openrouter, now: Self.now, currentValue: 12)

        let b = try #require(cache.baseline(for: .openrouter, on: Self.now))
        #expect(b.value == 12)
        #expect(b.date == Self.dayKey)
    }

    @Test("a legacy same-day accumulator keeps its running total")
    func legacyAccumulatorKept() throws {
        let cache = try Self.makeCache()
        _ = cache.accumulateDailyUsage(for: .claude, now: Self.now, deltaTokens: 100, deltaCostUSD: 1)
        try Self.rewriteDates(in: cache, to: Self.legacyKey)

        let total = cache.accumulateDailyUsage(for: .claude, now: Self.now, deltaTokens: 50, deltaCostUSD: 2)

        #expect(total.tokens == 150)
        #expect(total.costUSD == 3)
    }

    @Test("OpenRouter today cost survives a legacy same-day baseline")
    func openRouterCostSurvivesUpgrade() async throws {
        let cache = try Self.makeCache()
        cache.maintainBaseline(for: .openrouter, now: Self.now, currentValue: 40)
        try Self.rewriteDates(in: cache, to: Self.legacyKey)
        let key = OpenRouterKeyResponse(data: .init(
            label: "fake-label", limit: nil, limitReset: nil, limitRemaining: nil,
            includeByokInLimit: false, usage: 0, usageDaily: 0, usageWeekly: 0, usageMonthly: 0,
            byokUsage: 0, byokUsageDaily: 0, byokUsageWeekly: 0, byokUsageMonthly: 0,
            isFreeTier: false
        ))
        let client = FakeOpenRouterClient(
            creditsResult: .success(OpenRouterCreditsResponse(data: .init(totalCredits: 100, totalUsage: 42.5))),
            keyResult: .success(key)
        )
        let provider = OpenRouterProvider(
            client: client, cache: cache, clock: VirtualClock(fixed: Self.now), dayKeys: Self.owner()
        )

        let snap = try await provider.fetch(now: Self.now)

        #expect(snap.costTodayUSD == 2.5)
        let baseline = try #require(cache.baseline(for: .openrouter, on: Self.now))
        #expect(baseline.value == 40)
        #expect(baseline.date == Self.dayKey)
    }

    // MARK: Notification state

    @Test("migration rekeys legacy records and snooze days, once", arguments: [false, true])
    func migrationRekeysLegacyRecords(userDefaults: Bool) {
        let suite = "test.aub.daykey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state: any NotificationStateStorage = userDefaults
            ? UserDefaultsNotificationStateStore(defaults: defaults)
            : InMemoryNotificationStateStore()

        state.setRecord(
            NotificationStateRecord(lastBand: .warning, snoozedUntilDay: Self.legacyKey),
            forProviderID: .openrouter, day: Self.legacyKey
        )
        state.setRecord(
            NotificationStateRecord(lastBand: .critical, snoozedUntilDay: nil),
            forProviderID: .claude, day: Self.legacyYesterday
        )

        state.migrateLegacyDayKeys(Self.owner())

        #expect(state.record(forProviderID: .openrouter, day: Self.legacyKey) == nil)
        #expect(state.record(forProviderID: .openrouter, day: Self.dayKey)
            == NotificationStateRecord(lastBand: .warning, snoozedUntilDay: Self.dayKey))
        #expect(state.record(forProviderID: .claude, day: "2026-10-21")?.lastBand == .critical)

        // A second launch must not read day keys as legacy keys (2026 BE is 1483 CE).
        state.migrateLegacyDayKeys(Self.owner())
        #expect(state.record(forProviderID: .openrouter, day: Self.dayKey)?.lastBand == .warning)
        #expect(state.allRecordsForToday(Self.dayKey).count == 1)
    }

    @Test("prune reads Gregorian day keys on a Buddhist-calendar host")
    func pruneUsesGregorianKeys() {
        let state = InMemoryNotificationStateStore()
        let record = NotificationStateRecord(lastBand: .warning, snoozedUntilDay: nil)
        state.setRecord(record, forProviderID: .openrouter, day: Self.dayKey)
        state.setRecord(record, forProviderID: .openrouter, day: "2026-10-01")

        state.pruneOldKeys(olderThan: 7, today: Self.dayKey)

        #expect(state.record(forProviderID: .openrouter, day: Self.dayKey) != nil)
        #expect(state.record(forProviderID: .openrouter, day: "2026-10-01") == nil)
    }

    @Test("a band fired before the upgrade does not fire again on the upgrade day", arguments: [true, false])
    func bandDoesNotRefireAfterUpgrade(migrated: Bool) async {
        final class Capturing: NotificationManager, @unchecked Sendable {
            private(set) var scheduled: [NotificationDecision] = []
            func schedule(_ decisions: [NotificationDecision]) async { scheduled += decisions }
        }
        let state = InMemoryNotificationStateStore()
        state.setRecord(
            NotificationStateRecord(lastBand: .warning, snoozedUntilDay: nil),
            forProviderID: .openrouter, day: Self.legacyKey
        )
        if migrated { state.migrateLegacyDayKeys(Self.owner()) }

        let notifications = Capturing()
        let store = AggregateStore(
            registry: [FixedQuotaProvider(fraction: 0.85)],
            clock: VirtualClock(fixed: Self.now),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(dayKeys: Self.owner()),
            notifications: notifications,
            notificationState: state,
            dayKeys: Self.owner()
        )
        await store.refresh(now: Self.now)

        // Control: without the migration the legacy record is invisible and :warn80 fires again.
        #expect(notifications.scheduled.isEmpty == migrated)
    }

    /// OpenRouter at a fixed quota fraction.
    private actor FixedQuotaProvider: UsageProvider {
        nonisolated let id = ProviderID.openrouter
        nonisolated let displayName = "OpenRouter"
        nonisolated let capabilities = ProviderCapabilities(
            hasQuota: true, hasCost: true, hasTokens: false, isLocal: false
        )
        private let fraction: Double

        init(fraction: Double) { self.fraction = fraction }

        func status() -> ProviderStatus { .ok(lastSuccess: Date()) }

        func fetch(now: Date) async throws -> UsageSnapshot {
            UsageSnapshot(
                providerID: id, asOf: now, tokensToday: nil, costTodayUSD: nil, balanceUSD: nil,
                quota: Quota(used: fraction * 100, limit: 100, remaining: 100 - fraction * 100),
                raw: [:]
            )
        }
    }
}

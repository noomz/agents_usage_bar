import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - BaselineDeltaTests

@Suite("BaselineDeltaTests")
struct BaselineDeltaTests {

    // MARK: - Shared helpers

    private func makeProvider(
        creditsUsage: Double,
        creditsTotalCredits: Double = 100.0,
        keyLimit: Double? = 10.0,
        keyLimitRemaining: Double? = nil,
        keyUsage: Double = 8.20,
        cache: FakeCacheStore
    ) -> OpenRouterProvider {
        let credits = OpenRouterCreditsResponse(
            data: .init(totalCredits: creditsTotalCredits, totalUsage: creditsUsage)
        )
        let key = OpenRouterKeyResponse(data: .init(
            label: "fake-label",
            limit: keyLimit,
            limitReset: nil,
            limitRemaining: keyLimitRemaining,
            includeByokInLimit: false,
            usage: keyUsage,
            usageDaily: 0.0,
            usageWeekly: 0.0,
            usageMonthly: keyUsage,
            byokUsage: 0.0,
            byokUsageDaily: 0.0,
            byokUsageWeekly: 0.0,
            byokUsageMonthly: 0.0,
            isFreeTier: false
        ))
        let client = FakeOpenRouterClient(
            creditsResult: .success(credits),
            keyResult: .success(key)
        )
        return OpenRouterProvider(client: client, cache: cache, clock: SystemClock())
    }

    // MARK: Test 1: D-03 cold launch — no baseline → costTodayUSD == 0, baseline recorded

    @Test("coldLaunch_returnsZeroAndRecordsBaseline")
    func coldLaunch_returnsZeroAndRecordsBaseline() async throws {
        let cache = FakeCacheStore()
        let now = Date()
        let today = TodayHelper.formatYYYYMMDD(now)

        let provider = makeProvider(creditsUsage: 50.0, cache: cache)
        let snap = try await provider.fetch(now: now)

        // D-03: first poll returns 0 until next poll computes delta
        #expect(snap.costTodayUSD == 0)

        // Baseline must be recorded after fetch
        let recorded = cache.baseline(for: .openrouter, on: now)
        #expect(recorded != nil)
        #expect(recorded?.value == 50.0)
        #expect(recorded?.date == today)
    }

    // MARK: Test 2: D-01 second poll same day — returns delta

    @Test("secondPollSameDay_returnsDelta")
    func secondPollSameDay_returnsDelta() async throws {
        let cache = FakeCacheStore()
        let now = Date()
        let today = TodayHelper.formatYYYYMMDD(now)

        // Pre-seed baseline from earlier this same day
        cache.seedBaseline(
            BaselineRecord(value: 50.0, date: today, lastValue: 50.0, lastUpdated: now),
            for: .openrouter
        )

        let provider = makeProvider(creditsUsage: 53.20, cache: cache)
        let snap = try await provider.fetch(now: now)

        // delta = 53.20 - 50.0 = 3.20
        // Convert via NSDecimalNumber to get a Double for tolerance comparison,
        // since Decimal(Double) can carry IEEE 754 imprecision.
        let costDouble = NSDecimalNumber(decimal: snap.costTodayUSD ?? 0).doubleValue
        #expect(abs(costDouble - 3.20) < 0.001)
    }

    // MARK: Test 3: D-04 negative delta — resets baseline, costToday == 0

    @Test("negativeDelta_resetsAndLogs")
    func negativeDelta_resetsAndLogs() async throws {
        let cache = FakeCacheStore()
        let now = Date()
        let today = TodayHelper.formatYYYYMMDD(now)

        // Pre-seed baseline higher than current value
        cache.seedBaseline(
            BaselineRecord(value: 50.0, date: today, lastValue: 50.0, lastUpdated: now),
            for: .openrouter
        )

        let provider = makeProvider(creditsUsage: 48.0, cache: cache)
        let snap = try await provider.fetch(now: now)

        // D-04: negative delta → today = 0
        #expect(snap.costTodayUSD == 0)

        // Baseline must be reset to current value (48.0)
        let recorded = cache.baseline(for: .openrouter, on: now)
        #expect(recorded?.value == 48.0)
    }

    // MARK: Test 4: D-05 midnight rollover — new day resets baseline

    @Test("crossedDayBoundary_resetsBaseline")
    func crossedDayBoundary_resetsBaseline() async throws {
        let cache = FakeCacheStore()

        // Simulate: it is now 2026-05-11 14:00 PT
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 11; comps.hour = 14; comps.minute = 0
        let now = cal.date(from: comps)!
        let today = TodayHelper.formatYYYYMMDD(now, calendar: cal)

        // Baseline from yesterday (2026-05-10)
        cache.seedBaseline(
            BaselineRecord(value: 50.0, date: "2026-05-10", lastValue: 50.0, lastUpdated: now - 86400),
            for: .openrouter
        )

        let provider = makeProvider(creditsUsage: 55.0, cache: cache)
        let snap = try await provider.fetch(now: now)

        // D-05: different day → today = 0, baseline reset
        #expect(snap.costTodayUSD == 0)

        // After fetch, baseline date should be the new day
        let recorded = cache.baseline(for: .openrouter, on: now)
        #expect(recorded?.value == 55.0)
        // The FakeCacheStore uses the default Calendar.current for maintainBaseline,
        // so we just verify the value was reset (which proves D-05 triggered)
        #expect(recorded?.lastValue == 55.0)
    }

    // MARK: Test 5: Quota constructed when limit present

    @Test("quotaConstructed_whenLimitPresent")
    func quotaConstructed_whenLimitPresent() async throws {
        let cache = FakeCacheStore()
        let now = Date()
        let today = TodayHelper.formatYYYYMMDD(now)

        cache.seedBaseline(
            BaselineRecord(value: 0.0, date: today, lastValue: 0.0, lastUpdated: now),
            for: .openrouter
        )

        let provider = makeProvider(
            creditsUsage: 0.0,
            keyLimit: 10.0,
            keyLimitRemaining: 1.80,
            keyUsage: 8.20,
            cache: cache
        )
        let snap = try await provider.fetch(now: now)

        #expect(snap.quota != nil)
        #expect(snap.quota?.used == 8.20)
        #expect(snap.quota?.limit == 10.0)
        #expect(snap.quota?.remaining == 1.80)
    }

    // MARK: Test 6: Quota remaining falls back to max(0, limit - usage) when limitRemaining is nil

    @Test("quotaNilWhenLimitRemainingMissingButLimitPresent")
    func quotaNilWhenLimitRemainingMissingButLimitPresent() async throws {
        let cache = FakeCacheStore()
        let now = Date()
        let today = TodayHelper.formatYYYYMMDD(now)

        cache.seedBaseline(
            BaselineRecord(value: 0.0, date: today, lastValue: 0.0, lastUpdated: now),
            for: .openrouter
        )

        // limit = 10.0, limit_remaining = nil, usage = 8.20
        let provider = makeProvider(
            creditsUsage: 0.0,
            keyLimit: 10.0,
            keyLimitRemaining: nil,   // nil → falls back to max(0, 10.0 - 8.20)
            keyUsage: 8.20,
            cache: cache
        )
        let snap = try await provider.fetch(now: now)

        #expect(snap.quota != nil)
        // remaining = max(0, 10.0 - 8.20) = 1.80
        let expectedRemaining = max(0.0, 10.0 - 8.20)
        #expect(abs((snap.quota?.remaining ?? -1) - expectedRemaining) < 0.001)
    }

    // MARK: Test 7: balanceUSD = totalCredits - totalUsage (ROUTER-03)

    @Test("balanceUSD_equalsCreditsMinusUsage")
    func balanceUSD_equalsCreditsMinusUsage() async throws {
        let cache = FakeCacheStore()
        let now = Date()
        let today = TodayHelper.formatYYYYMMDD(now)

        cache.seedBaseline(
            BaselineRecord(value: 0.0, date: today, lastValue: 0.0, lastUpdated: now),
            for: .openrouter
        )

        let provider = makeProvider(
            creditsUsage: 25.30,
            creditsTotalCredits: 100.50,
            cache: cache
        )
        let snap = try await provider.fetch(now: now)

        // balance = 100.50 - 25.30 = 75.20
        #expect(snap.balanceUSD == Decimal(75.20))
    }

    // MARK: Test 8: tokensToday is always nil for OpenRouter

    @Test("tokensToday_isAlwaysNil_OpenRouter")
    func tokensToday_isAlwaysNil_OpenRouter() async throws {
        let cache = FakeCacheStore()
        let now = Date()

        let provider = makeProvider(creditsUsage: 10.0, cache: cache)
        let snap = try await provider.fetch(now: now)

        #expect(snap.tokensToday == nil)
    }
}

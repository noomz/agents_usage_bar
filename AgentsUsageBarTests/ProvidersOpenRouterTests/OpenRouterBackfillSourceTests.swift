import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("OpenRouterBackfillSourceTests")
struct OpenRouterBackfillSourceTests {

    /// Synthetic `/activity` body: two models on one UTC day, one on another, and a day
    /// outside the asked keys.
    private static let activityJSON = """
    {"data": [
      {"date": "2026-10-20", "model": "vendor/model-a", "model_permaslug": "vendor/model-a-1",
       "endpoint_id": "00000000-0000-0000-0000-000000000001", "provider_name": "Vendor",
       "usage": 0.1, "byok_usage_inference": 5, "requests": 2,
       "prompt_tokens": 100, "completion_tokens": 50, "reasoning_tokens": 10, "cached_tokens": 0},
      {"date": "2026-10-20", "model": "vendor/model-b", "model_permaslug": "vendor/model-b-1",
       "endpoint_id": "00000000-0000-0000-0000-000000000002", "provider_name": "Vendor",
       "usage": 0.2, "byok_usage_inference": 0, "requests": 1,
       "prompt_tokens": 200, "completion_tokens": 25, "reasoning_tokens": 0, "cached_tokens": 0},
      {"date": "2026-10-18", "model": "vendor/model-a", "model_permaslug": "vendor/model-a-1",
       "endpoint_id": "00000000-0000-0000-0000-000000000001", "provider_name": "Vendor",
       "usage": 9, "byok_usage_inference": 0, "requests": 1,
       "prompt_tokens": 1, "completion_tokens": 1, "reasoning_tokens": 0, "cached_tokens": 0}
    ]}
    """

    private static func decoded() throws -> OpenRouterActivityResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(OpenRouterActivityResponse.self, from: Data(activityJSON.utf8))
    }

    private static func source(at iso: String) throws -> OpenRouterBackfillSource {
        let response = try decoded()
        let now = ISO8601DateFormatter().date(from: iso)!
        return OpenRouterBackfillSource(clock: VirtualClock(fixed: now)) { response }
    }

    @Test("holds only completed UTC days among the last 30, whatever the local date (V63)")
    func holdsCompletedUTCDays() throws {
        // 03:00 on 2026-10-22 in Bangkok is still 2026-10-21 in UTC, which is in progress.
        let source = try Self.source(at: "2026-10-21T20:00:00Z")
        #expect(!source.holds("2026-10-21"))
        #expect(source.holds("2026-10-20"))
        #expect(source.holds("2026-09-21"))
        #expect(!source.holds("2026-09-20"))
    }

    @Test("one UTC record per key: credit spend summed, prompt plus completion tokens, zero where none (V13, V30)")
    func sumsPerUTCDay() async throws {
        let source = try Self.source(at: "2026-10-22T12:00:00Z")
        let records = try await source.records(for: ["2026-10-19", "2026-10-20"])

        #expect(records["2026-10-20"] == DayRecord(
            provider: .openrouter, timeZone: "UTC", tokens: 375, costUSD: Money(Decimal(string: "0.3")!),
            costEstimated: false, origin: .backfilled))
        #expect(records["2026-10-19"] == DayRecord(
            provider: .openrouter, timeZone: "UTC", tokens: 0, costUSD: Money(0), origin: .backfilled))
        #expect(records["2026-10-18"] == nil)
    }

    @Test("lists one metered default account, as the live poll does (I6, V62)")
    func meteredDefaultAccount() async throws {
        let accounts = await (try Self.source(at: "2026-10-22T12:00:00Z")).accounts()
        #expect(accounts.map(\.name) == [DayAccount.defaultKey])
        #expect(accounts.first?.accountInfo?.billingModel == .metered)
    }

    @Test("reach is 30 days (V28)")
    func reach() async throws {
        #expect(await (try Self.source(at: "2026-10-22T12:00:00Z")).reachDays() == 30)
    }
}

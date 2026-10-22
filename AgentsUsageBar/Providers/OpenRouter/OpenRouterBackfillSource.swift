import Foundation

/// OpenRouter's past days rebuilt from `GET /activity` (SPEC I10, V28). The endpoint serves
/// the last 30 completed UTC days, so UTC day `D` fills key `D` and the record says `UTC`
/// (V13). A key whose UTC day is still in progress or older than 30 days is not held (V63).
/// Cost is OpenRouter's own credit spend, so it is reported, not estimated.
struct OpenRouterBackfillSource: BackfillSource {
    static let reach = 30
    static let timeZone = "UTC"

    let provider: ProviderID = .openrouter
    private let utc: DayKeyOwner
    private let fetchActivity: @Sendable () async throws -> OpenRouterActivityResponse

    init(clock: any Clock, fetchActivity: @escaping @Sendable () async throws -> OpenRouterActivityResponse) {
        self.utc = DayKeyOwner(clock: clock, timeZone: TimeZone(identifier: Self.timeZone)!)
        self.fetchActivity = fetchActivity
    }

    func reachDays() async -> Int? {
        Self.reach
    }

    func holds(_ key: String) -> Bool {
        let today = utc.today()
        guard let oldest = utc.key(today, addingDays: -Self.reach) else { return false }
        return key >= oldest && key < today
    }

    /// One record per key from a single request, which returns every served day.
    func records(for keys: [String]) async throws -> [String: DayRecord] {
        let wanted = Set(keys)
        var tokens: [String: Int] = [:]
        var cost: [String: Decimal] = [:]
        for item in try await fetchActivity().data where wanted.contains(item.date) {
            tokens[item.date, default: 0] += item.promptTokens + item.completionTokens
            cost[item.date, default: 0] += item.usage
        }
        return Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, DayRecord(
                provider: provider, timeZone: Self.timeZone, tokens: tokens[key] ?? 0,
                costUSD: Money(cost[key] ?? 0), origin: .backfilled))
        })
    }

    /// One metered `default` account, as the live poll records it (I6).
    func accounts() async -> [UsageSnapshot.AccountUsage] {
        [UsageSnapshot.AccountUsage(
            name: DayAccount.defaultKey, costTodayUSD: nil, quota: nil, quotaWindows: nil,
            accountInfo: AccountInfo(billingModel: .metered))]
    }
}

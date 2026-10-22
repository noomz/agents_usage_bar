import Foundation

/// Codex's past days rebuilt from rollouts, which the Codex CLI never expires, so reach is the
/// whole retention window (SPEC I10, V28). Cost is tokens times the bundled price table (I8,
/// V10).
struct CodexBackfillSource: BackfillSource {
    let provider: ProviderID = .codex
    private let pricing: CodexModelPricing?
    private let dayKeys: DayKeyOwner
    private let root: @Sendable () -> URL?
    private let logins: @Sendable () -> [CodexDiscoveredLogin]

    init(
        pricing: CodexModelPricing?,
        dayKeys: DayKeyOwner,
        root: @escaping @Sendable () -> URL? = { CodexRoots.defaultRoot },
        logins: @escaping @Sendable () -> [CodexDiscoveredLogin]
    ) {
        self.pricing = pricing
        self.dayKeys = dayKeys
        self.root = root
        self.logins = logins
    }

    func reachDays() async -> Int? {
        root() == nil ? nil : HistoryStore.retainedDays
    }

    /// One record per key. Rollouts filed under the day before the first key are read too,
    /// since a session can run past midnight.
    func records(for keys: [String]) async throws -> [String: DayRecord] {
        guard let first = keys.min(), let last = keys.max() else { return [:] }
        var directories: [String] = []
        var key = dayKeys.key(first, addingDays: -1)
        while let day = key, day <= last {
            directories.append(day)
            key = dayKeys.key(day, addingDays: 1)
        }
        let files = CodexRolloutScanner(now: .now, root: root()).rolloutFiles(forDayKeys: directories)
        let usage = CodexRolloutParser.dailyUsage(in: files, dayKey: dayKeys.wallKey(for:))
        return Dictionary(uniqueKeysWithValues: keys.map { key in
            let day = usage[key] ?? CodexDayUsage()
            let cost = pricing?.cost(
                inputTokens: day.inputTokens,
                cachedInputTokens: day.cachedInputTokens,
                outputTokens: day.outputTokens,
                reasoningOutputTokens: day.reasoningOutputTokens,
                modelID: nil
            )
            return (key, DayRecord(
                provider: provider, tokens: day.totalTokens, costUSD: cost.map(Money.init),
                costEstimated: cost != nil, origin: .backfilled))
        })
    }

    /// The discovered subscription logins, or one metered `default` account when there are
    /// none, since Codex then runs on an API key (I6, V62).
    func accounts() async -> [UsageSnapshot.AccountUsage] {
        let discovered = logins()
        guard !discovered.isEmpty else {
            return [UsageSnapshot.AccountUsage(
                name: DayAccount.defaultKey, costTodayUSD: nil, quota: nil, quotaWindows: nil,
                accountInfo: AccountInfo(billingModel: .metered))]
        }
        return CodexLoginDiscovery.labeled(discovered).map { item in
            UsageSnapshot.AccountUsage(
                name: item.label, costTodayUSD: nil, quota: nil, quotaWindows: nil,
                accountInfo: AccountInfo(
                    billingModel: .subscription, plan: item.login.planSuffix, accountID: item.login.accountId))
        }
    }
}

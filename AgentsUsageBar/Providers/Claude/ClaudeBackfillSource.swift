import Foundation

/// Claude's past days rebuilt from transcripts (SPEC I10, V28). Claude Code deletes
/// transcripts by file age once they pass its `cleanupPeriodDays` (default 30), so the 30th
/// day back may be partly gone and reach stops one day short of it. Cost is tokens times the
/// bundled price table (I8, V10).
struct ClaudeBackfillSource: BackfillSource {
    static let reach = 29

    let provider: ProviderID = .claude
    private let pricing: ClaudeModelPricing
    private let dayKeys: DayKeyOwner
    private let roots: @Sendable () -> [URL]
    private let home: URL
    private let reader = TranscriptReader()
    private let scanner = TranscriptDirectoryScanner()

    init(
        pricing: ClaudeModelPricing,
        dayKeys: DayKeyOwner,
        roots: @escaping @Sendable () -> [URL] = { ClaudeRoots.defaultRoots },
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.pricing = pricing
        self.dayKeys = dayKeys
        self.roots = roots
        self.home = home
    }

    func reachDays() async -> Int? {
        roots().contains { FileManager.default.fileExists(atPath: $0.path) } ? Self.reach : nil
    }

    /// One record per key. Files are read one at a time; a file untouched since before the
    /// first day cannot hold it. Records are deduplicated by request id across files, since ccs
    /// roots can reach one transcript through several paths.
    func records(for keys: [String]) async throws -> [String: DayRecord] {
        guard let first = keys.min() else { return [:] }
        let wanted = Set(keys)
        let files = Set(scanner.scanRoots(roots(), modifiedSince: dayKeys.start(of: first)))
        var tokens: [String: Int] = [:]
        var cost: [String: Decimal] = [:]
        var seenRequestIDs: Set<String> = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            let read = try await reader.readDelta(from: file, startOffset: 0, previousLastModified: nil)
            for record in read.records {
                let key = dayKeys.wallKey(for: record.timestamp)
                guard wanted.contains(key) else { continue }
                if let requestID = record.requestID {
                    guard seenRequestIDs.insert(requestID).inserted else { continue }
                }
                tokens[key, default: 0] += record.totalTokens
                cost[key, default: 0] += pricing.cost(
                    inputTokens: record.inputTokens,
                    outputTokens: record.outputTokens,
                    cacheCreationTokens: record.cacheCreationTokens,
                    cacheReadTokens: record.cacheReadTokens,
                    modelID: record.model
                )
            }
        }
        return Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, DayRecord(
                provider: provider, tokens: tokens[key] ?? 0, costUSD: Money(cost[key] ?? 0),
                costEstimated: true, origin: .backfilled))
        })
    }

    /// `default` when `~/.claude.json` exists, then each ccs instance with a `.claude.json`,
    /// billed from that file (I6, V62).
    func accounts() async -> [UsageSnapshot.AccountUsage] {
        let fm = FileManager.default
        let instances = (try? fm.contentsOfDirectory(
            atPath: home.appending(path: ".ccs/instances").path(percentEncoded: false))) ?? []
        let names = ([DayAccount.defaultKey] + instances.filter { !$0.hasPrefix(".") }.sorted())
            .filter { fm.fileExists(atPath: ClaudeAccountPlans.claudeJSON(for: $0, home: home).path(percentEncoded: false)) }
        var plans = ClaudeAccountPlans(home: home)
        return names.map { name in
            UsageSnapshot.AccountUsage(
                name: name, costTodayUSD: nil, quota: nil, quotaWindows: nil,
                accountInfo: plans.info(for: name))
        }
    }
}

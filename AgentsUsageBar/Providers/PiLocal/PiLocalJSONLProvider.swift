import Foundation
import os

public actor PiLocalJSONLProvider: UsageProvider {
    public nonisolated let id: ProviderID = .piLocal
    public nonisolated let displayName: String = "Local Llama"
    public nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: false,
        hasCost: true,
        hasTokens: true,
        isLocal: false
    )

    private let scanner: TranscriptDirectoryScanner
    private let reader: PiSessionReader
    private let sessionRoots: @Sendable () -> [URL]
    private let loadCatalog: @Sendable () -> PiLocalCatalog
    private let cache: any CacheStore
    private let clock: any Clock
    private let logger = AppLogger.logger(category: "pi-local")
    private var lastStatus: ProviderStatus = .error(ProviderError.notYetFetched)

    init(
        scanner: TranscriptDirectoryScanner,
        reader: PiSessionReader,
        sessionRoots: @escaping @Sendable () -> [URL],
        loadCatalog: @escaping @Sendable () -> PiLocalCatalog,
        cache: any CacheStore,
        clock: any Clock
    ) {
        self.scanner = scanner
        self.reader = reader
        self.sessionRoots = sessionRoots
        self.loadCatalog = loadCatalog
        self.cache = cache
        self.clock = clock
    }

    public func status() -> ProviderStatus {
        lastStatus
    }

    public func fetch(now: Date) async throws -> UsageSnapshot {
        let roots = sessionRoots()
        let catalog = loadCatalog()
        if !roots.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            lastStatus = .unauthenticated
            return UsageSnapshot(
                providerID: id,
                asOf: now,
                tokensToday: 0,
                costTodayUSD: 0,
                balanceUSD: nil,
                quota: nil,
                raw: ["providerStatus": "unauthenticated"]
            )
        }

        do {
            let todayStart = TodayHelper.startOfDay(now)
            let priorOffsets = cache.allTranscriptOffsets()
            let scanFloor = priorOffsets.values.map(\.lastModified).min()
                .map { $0.addingTimeInterval(-1) }
            let candidateFiles = scanner.scanRoots(roots, modifiedSince: scanFloor)

            var newOffsets: [String: TranscriptOffset] = [:]
            var acc = PiLocalUsage.Acc()

            let reader = self.reader
            try await withThrowingTaskGroup(of: (URL, PiSessionReader.ReadResult).self) { group in
                for fileURL in candidateFiles {
                    let priorOffset = priorOffsets[fileURL.absoluteString]?.byteOffset ?? 0
                    let priorMTime = priorOffsets[fileURL.absoluteString]?.lastModified
                    group.addTask {
                        let result = try reader.readDelta(
                            from: fileURL,
                            startOffset: priorOffset,
                            previousLastModified: priorMTime
                        )
                        return (fileURL, result)
                    }
                }

                for try await (fileURL, result) in group {
                    newOffsets[fileURL.absoluteString] = TranscriptOffset(
                        url: fileURL.absoluteString,
                        byteOffset: result.newOffset,
                        lastModified: result.lastModified
                    )
                    PiLocalUsage.reduce(
                        records: result.records,
                        catalog: catalog,
                        todayStart: todayStart,
                        into: &acc
                    )
                }
            }

            cache.setTranscriptOffsets(Array(newOffsets.values))

            let (todayTokensTotal, todayCostTotal, _) = cache.accumulateDailyUsage(
                for: id,
                now: now,
                deltaTokens: acc.tokens,
                deltaCostUSD: acc.costUSD,
                deltaSessionTokens: [:]
            )

            lastStatus = .ok(lastSuccess: now)
            var snap = UsageSnapshot(
                providerID: id,
                asOf: now,
                tokensToday: todayTokensTotal,
                costTodayUSD: todayCostTotal,
                balanceUSD: nil,
                quota: nil,
                raw: [
                    "providers": acc.providers.map(\.rawValue).sorted().joined(separator: ","),
                    "models": acc.models.sorted().joined(separator: ","),
                    "filesRead": "\(candidateFiles.count)",
                ]
            )
            snap.accountInfo = AccountInfo(billingModel: .local)
            return snap
        } catch {
            lastStatus = .error(ProviderError.from(error))
            logger.error("fetch failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

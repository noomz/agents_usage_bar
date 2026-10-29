import Foundation
import os

/// Grok usage row: CLI SuperGrok quota, xAI Management API balance, and today's
/// Pi/Hermes `xai` JSONL spend. SuperGrok % still comes only from CLI billing (V70).
public actor GrokBillingProvider: UsageProvider {

    public nonisolated let id: ProviderID = .grok
    public nonisolated let displayName: String = "Grok"
    public nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: true,
        hasCost: true,
        hasTokens: true,
        isLocal: false
    )

    public static let degradedNote = ThresholdEngine.degradedTag
    private static let jsonlOffsetPrefix = "grok:"
    private static let xaiCatalog = PiLocalCatalog(names: [PiProviderName(rawValue: "xai")])

    private let client: any GrokBillingClientProtocol
    private let management: (any GrokManagementClientProtocol)?
    private let clock: any Clock
    private let scanner: TranscriptDirectoryScanner?
    private let reader: PiSessionReader?
    private let sessionRoots: (@Sendable () -> [URL])?
    private let cache: (any CacheStore)?
    private let logger = AppLogger.logger(category: "grok")
    private var lastStatus: ProviderStatus = .error(ProviderError.notYetFetched)
    private var lastGoodSnapshot: UsageSnapshot?

    public init(
        client: any GrokBillingClientProtocol,
        management: (any GrokManagementClientProtocol)? = nil,
        clock: any Clock
    ) {
        self.init(
            client: client,
            management: management,
            clock: clock,
            scanner: nil,
            reader: nil,
            sessionRoots: nil,
            cache: nil
        )
    }

    init(
        client: any GrokBillingClientProtocol,
        management: (any GrokManagementClientProtocol)? = nil,
        clock: any Clock,
        scanner: TranscriptDirectoryScanner?,
        reader: PiSessionReader?,
        sessionRoots: (@Sendable () -> [URL])?,
        cache: (any CacheStore)?
    ) {
        self.client = client
        self.management = management
        self.clock = clock
        self.scanner = scanner
        self.reader = reader
        self.sessionRoots = sessionRoots
        self.cache = cache
    }

    public func status() -> ProviderStatus {
        lastStatus
    }

    public func fetch(now: Date) async throws -> UsageSnapshot {
        let cli = await loadCLI()
        let mgmt = await loadManagement(now: now)
        let jsonl = await loadJSONL(now: now)

        if let billing = cli.billing, !isEmpty(billing) {
            let snap = buildSnapshot(from: billing, management: mgmt.snapshot, jsonl: jsonl, now: now)
            lastGoodSnapshot = snap
            lastStatus = .ok(lastSuccess: now)
            let percent = billing.normalizedPercent.map { String(Int(($0 * 100).rounded())) } ?? "nil"
            logger.notice("grok billing percent=\(percent, privacy: .public) period=\(billing.periodLabel ?? "nil", privacy: .public)")
            return snap
        }

        if let mgmtSnap = mgmt.snapshot {
            let snap = buildSnapshot(from: nil, management: mgmtSnap, jsonl: jsonl, now: now)
            lastGoodSnapshot = snap
            lastStatus = .ok(lastSuccess: now)
            logger.notice("grok management spend present")
            return snap
        }

        if jsonl.contributed {
            let snap = buildSnapshot(from: nil, management: nil, jsonl: jsonl, now: now)
            lastGoodSnapshot = snap
            lastStatus = .ok(lastSuccess: now)
            logger.notice("grok pi-jsonl xai spend present")
            return snap
        }

        if cli.failedHard {
            return degrade(now: now, error: cli.error ?? GrokBillingError.billingEndpointFailed(status: 0))
        }
        return retainLastGoodOrMute(
            now: now,
            error: mgmt.error ?? cli.error ?? GrokBillingError.emptyPayload
        )
    }

    private struct CLILoad {
        var billing: GrokBillingResponse?
        var error: Error?
        var failedHard: Bool
    }

    private struct ManagementLoad {
        var snapshot: GrokManagementSnapshot?
        var error: Error?
    }

    private struct JSONLLoad {
        var contributed: Bool
        var tokens: Int
        var costUSD: Decimal

        static let skipped = JSONLLoad(contributed: false, tokens: 0, costUSD: 0)
    }

    private func loadCLI() async -> CLILoad {
        do {
            let billing = try await client.fetchCredits()
            if isEmpty(billing) {
                logger.warning("grok billing empty payload — keeping last good snapshot")
                return CLILoad(billing: nil, error: GrokBillingError.emptyPayload, failedHard: false)
            }
            return CLILoad(billing: billing, error: nil, failedHard: false)
        } catch GrokBillingError.noCredentials {
            return CLILoad(billing: nil, error: GrokBillingError.noCredentials, failedHard: false)
        } catch GrokBillingError.unauthorized {
            logger.warning("grok billing unauthorized — keeping last good snapshot if any")
            return CLILoad(billing: nil, error: GrokBillingError.unauthorized(status: 401), failedHard: false)
        } catch {
            return CLILoad(billing: nil, error: error, failedHard: true)
        }
    }

    private func loadManagement(now: Date) async -> ManagementLoad {
        guard let management else {
            return ManagementLoad(snapshot: nil, error: nil)
        }
        do {
            return ManagementLoad(snapshot: try await management.fetch(now: now), error: nil)
        } catch {
            logger.warning("grok management failed: \(String(describing: error), privacy: .public)")
            return ManagementLoad(snapshot: nil, error: error)
        }
    }

    private func loadJSONL(now: Date) async -> JSONLLoad {
        guard let scanner, let reader, let sessionRoots, let cache else {
            return .skipped
        }
        let roots = sessionRoots()
        let todayStart = TodayHelper.startOfDay(now)
        let priorOffsets = cache.allTranscriptOffsets()
        let grokOffsets = priorOffsets.filter { $0.key.hasPrefix(Self.jsonlOffsetPrefix) }
        let scanFloor = grokOffsets.values.map(\.lastModified).min()
            .map { $0.addingTimeInterval(-1) }
        let candidateFiles = scanner.scanRoots(roots, modifiedSince: scanFloor)

        var newOffsets: [String: TranscriptOffset] = [:]
        var acc = PiLocalUsage.Acc()

        do {
            try await withThrowingTaskGroup(of: (URL, PiSessionReader.ReadResult).self) { group in
                for fileURL in candidateFiles {
                    let key = Self.jsonlOffsetPrefix + fileURL.absoluteString
                    let priorOffset = priorOffsets[key]?.byteOffset ?? 0
                    let priorMTime = priorOffsets[key]?.lastModified
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
                    let key = Self.jsonlOffsetPrefix + fileURL.absoluteString
                    newOffsets[key] = TranscriptOffset(
                        url: key,
                        byteOffset: result.newOffset,
                        lastModified: result.lastModified
                    )
                    PiLocalUsage.reduce(
                        records: result.records,
                        catalog: Self.xaiCatalog,
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
            let contributed = !acc.providers.isEmpty || todayTokensTotal > 0 || todayCostTotal > 0
            guard contributed else { return .skipped }
            return JSONLLoad(contributed: true, tokens: todayTokensTotal, costUSD: todayCostTotal)
        } catch {
            logger.warning("grok pi-jsonl failed: \(String(describing: error), privacy: .public)")
            return .skipped
        }
    }

    /// True when the payload cannot drive a quota bar or reset countdown.
    private func isEmpty(_ billing: GrokBillingResponse) -> Bool {
        billing.makeQuota() == nil
            && billing.normalizedPercent == nil
            && billing.billingPeriodEnd == nil
    }

    /// Never apply an empty/"logged out" snapshot over a previously good row.
    /// Returning the last good snapshot as success keeps the row's data instead
    /// of blanking it on a transient logged-out read.
    private func retainLastGoodOrMute(now: Date, error: Error) -> UsageSnapshot {
        if let last = lastGoodSnapshot {
            lastStatus = .ok(lastSuccess: last.asOf)
            return last
        }
        switch error as? GrokBillingError {
        case .unauthorized, .noCredentials:
            lastStatus = .unauthenticated
            return mutedNoData(now: now, tagged: false)
        default:
            lastStatus = .error(ProviderError.from(error))
            return mutedNoData(now: now, tagged: true)
        }
    }

    private func buildSnapshot(
        from billing: GrokBillingResponse?,
        management: GrokManagementSnapshot?,
        jsonl: JSONLLoad,
        now: Date
    ) -> UsageSnapshot {
        let quota = billing?.makeQuota()
        var raw: [String: String] = [:]
        if let tier = billing?.subscriptionTier { raw["subscriptionTier"] = tier }
        if let period = billing?.periodLabel ?? billing?.currentPeriod { raw["period"] = period }
        if let product = billing?.productLabel { raw["product"] = product }
        if let prepaid = billing?.prepaidBalance { raw["prepaidBalance"] = String(prepaid) }
        var sources: [String] = []
        if management != nil { sources.append("management") }
        if jsonl.contributed { sources.append("pi-jsonl") }
        if !sources.isEmpty { raw["source"] = sources.joined(separator: ",") }

        let window: [QuotaWindow]?
        if let billing, let percent = billing.normalizedPercent {
            window = [
                QuotaWindow(
                    name: "billing",
                    utilization: percent,
                    resetsAt: billing.billingPeriodEnd
                )
            ]
        } else {
            window = nil
        }

        let cliBalance: Decimal?
        if let prepaid = billing?.prepaidBalance, prepaid > 0 {
            cliBalance = Decimal(prepaid)
        } else {
            cliBalance = nil
        }
        let balance = management?.remainingUSD ?? cliBalance
        let tokensToday: Int? = jsonl.contributed ? jsonl.tokens : nil
        let costTodayUSD: Decimal? = jsonl.contributed ? jsonl.costUSD : management?.costTodayUSD

        var tooltipParts: [String] = []
        if let product = billing?.productLabel { tooltipParts.append(product) }
        if let period = billing?.periodLabel { tooltipParts.append(period.capitalized) }
        if let tier = billing?.subscriptionTier { tooltipParts.append(tier) }
        if billing == nil, management != nil { tooltipParts.append("API") }

        return UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: tokensToday,
            costTodayUSD: costTodayUSD,
            balanceUSD: balance,
            quota: quota,
            raw: raw,
            quotaWindows: window,
            tooltipLabel: tooltipParts.isEmpty ? nil : tooltipParts.joined(separator: " · ")
        )
    }

    private func degrade(now: Date, error: Error) -> UsageSnapshot {
        let pe = ProviderError.from(error)
        logger.warning("grok billing degraded: \(pe.message, privacy: .public)")
        if let cached = lastGoodSnapshot {
            var raw = cached.raw
            raw["note"] = Self.degradedNote
            raw["degraded"] = "true"
            lastStatus = .stale(lastSuccess: cached.asOf, error: pe)
            return UsageSnapshot(
                providerID: cached.providerID,
                asOf: cached.asOf,
                tokensToday: cached.tokensToday,
                costTodayUSD: cached.costTodayUSD,
                balanceUSD: cached.balanceUSD,
                quota: cached.quota,
                raw: raw,
                quotaWindows: cached.quotaWindows,
                tooltipLabel: cached.tooltipLabel
            )
        }
        lastStatus = .error(pe)
        return mutedNoData(now: now, tagged: true)
    }

    private func mutedNoData(now: Date, tagged: Bool) -> UsageSnapshot {
        var raw: [String: String] = ["status": "no-data-yet"]
        if tagged {
            raw["note"] = Self.degradedNote
        }
        return UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: raw,
            quotaWindows: nil,
            tooltipLabel: nil
        )
    }
}

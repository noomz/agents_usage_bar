import Foundation
import os

/// Grok usage row: CLI SuperGrok quota plus xAI Management API spend/balance (V70).
/// `hasTokens` stays false (no token count from either API). `hasCost` is true so
/// management today-USD rolls into the header when present.
public actor GrokBillingProvider: UsageProvider {

    public nonisolated let id: ProviderID = .grok
    public nonisolated let displayName: String = "Grok"
    public nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: true,
        hasCost: true,
        hasTokens: false,
        isLocal: false
    )

    public static let degradedNote = ThresholdEngine.degradedTag

    private let client: any GrokBillingClientProtocol
    private let management: (any GrokManagementClientProtocol)?
    private let clock: any Clock
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
        _ = scanner
        _ = reader
        _ = sessionRoots
        _ = cache
    }

    public func status() -> ProviderStatus {
        lastStatus
    }

    public func fetch(now: Date) async throws -> UsageSnapshot {
        let cli = await loadCLI()
        let mgmt = await loadManagement(now: now)

        if let billing = cli.billing, !isEmpty(billing) {
            let snap = buildSnapshot(from: billing, management: mgmt.snapshot, now: now)
            lastGoodSnapshot = snap
            lastStatus = .ok(lastSuccess: now)
            let percent = billing.normalizedPercent.map { String(Int(($0 * 100).rounded())) } ?? "nil"
            logger.notice("grok billing percent=\(percent, privacy: .public) period=\(billing.periodLabel ?? "nil", privacy: .public)")
            return snap
        }

        if let mgmtSnap = mgmt.snapshot {
            let snap = buildSnapshot(from: nil, management: mgmtSnap, now: now)
            lastGoodSnapshot = snap
            lastStatus = .ok(lastSuccess: now)
            logger.notice("grok management spend present")
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
        now: Date
    ) -> UsageSnapshot {
        let quota = billing?.makeQuota()
        var raw: [String: String] = [:]
        if let tier = billing?.subscriptionTier { raw["subscriptionTier"] = tier }
        if let period = billing?.periodLabel ?? billing?.currentPeriod { raw["period"] = period }
        if let product = billing?.productLabel { raw["product"] = product }
        if let prepaid = billing?.prepaidBalance { raw["prepaidBalance"] = String(prepaid) }
        if management != nil { raw["source"] = "management" }

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

        var tooltipParts: [String] = []
        if let product = billing?.productLabel { tooltipParts.append(product) }
        if let period = billing?.periodLabel { tooltipParts.append(period.capitalized) }
        if let tier = billing?.subscriptionTier { tooltipParts.append(tier) }
        if billing == nil, management != nil { tooltipParts.append("API") }

        return UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: management?.costTodayUSD,
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
                tokensToday: nil,
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

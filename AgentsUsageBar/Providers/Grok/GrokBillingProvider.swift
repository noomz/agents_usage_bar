import Foundation
import os

/// Grok Build TUI usage row. Billing-quota only — session files do not persist
/// billed tokens, so `tokensToday` and `costTodayUSD` are always nil (D-07 /
/// Gemini shape). `capabilities.hasTokens == false` excludes the row from
/// today-total rollup.
public actor GrokBillingProvider: UsageProvider {

    public nonisolated let id: ProviderID = .grok
    public nonisolated let displayName: String = "Grok"
    public nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: true,
        hasCost: false,
        hasTokens: false,
        isLocal: false
    )

    public static let degradedNote = ThresholdEngine.degradedTag

    private let client: any GrokBillingClientProtocol
    private let clock: any Clock
    private let logger = AppLogger.logger(category: "grok")
    private var lastStatus: ProviderStatus = .error(ProviderError.notYetFetched)
    private var lastGoodSnapshot: UsageSnapshot?

    public init(client: any GrokBillingClientProtocol, clock: any Clock) {
        self.client = client
        self.clock = clock
    }

    public func status() -> ProviderStatus {
        lastStatus
    }

    public func fetch(now: Date) async throws -> UsageSnapshot {
        do {
            let billing = try await client.fetchCredits()
            if isEmpty(billing) {
                logger.warning("grok billing empty payload — keeping last good snapshot")
                return retainLastGoodOrMute(now: now, error: GrokBillingError.emptyPayload)
            }
            let snap = buildSnapshot(from: billing, now: now)
            lastGoodSnapshot = snap
            lastStatus = .ok(lastSuccess: now)
            let percent = billing.normalizedPercent.map { String(Int(($0 * 100).rounded())) } ?? "nil"
            logger.notice("grok billing percent=\(percent, privacy: .public) period=\(billing.periodLabel ?? "nil", privacy: .public)")
            return snap
        } catch GrokBillingError.noCredentials {
            return retainLastGoodOrMute(now: now, error: GrokBillingError.noCredentials)
        } catch GrokBillingError.unauthorized {
            logger.warning("grok billing unauthorized — keeping last good snapshot if any")
            return retainLastGoodOrMute(now: now, error: GrokBillingError.unauthorized(status: 401))
        } catch {
            return degrade(now: now, error: error)
        }
    }

    /// True when the payload cannot drive a quota bar or reset countdown.
    private func isEmpty(_ billing: GrokBillingResponse) -> Bool {
        billing.makeQuota() == nil
            && billing.normalizedPercent == nil
            && billing.billingPeriodEnd == nil
    }

    /// Never apply an empty/"logged out" snapshot over a previously good row.
    /// Returning the last good snapshot as success keeps POLL-06 from freezing
    /// the provider (401-as-unauthenticated would skip all future polls).
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

    private func buildSnapshot(from billing: GrokBillingResponse, now: Date) -> UsageSnapshot {
        let quota = billing.makeQuota()
        var raw: [String: String] = [:]
        if let tier = billing.subscriptionTier { raw["subscriptionTier"] = tier }
        if let period = billing.periodLabel ?? billing.currentPeriod { raw["period"] = period }
        if let product = billing.productLabel { raw["product"] = product }
        if let prepaid = billing.prepaidBalance { raw["prepaidBalance"] = String(prepaid) }

        let window: [QuotaWindow]?
        if let percent = billing.normalizedPercent {
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

        let balance: Decimal?
        if let prepaid = billing.prepaidBalance, prepaid > 0 {
            balance = Decimal(prepaid)
        } else {
            balance = nil
        }

        var tooltipParts: [String] = []
        if let product = billing.productLabel { tooltipParts.append(product) }
        if let period = billing.periodLabel { tooltipParts.append(period.capitalized) }
        if let tier = billing.subscriptionTier { tooltipParts.append(tier) }

        return UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
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
                costTodayUSD: nil,
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

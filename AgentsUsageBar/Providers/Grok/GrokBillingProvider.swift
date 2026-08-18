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
            let snap = buildSnapshot(from: billing, now: now)
            lastGoodSnapshot = snap
            lastStatus = .ok(lastSuccess: now)
            return snap
        } catch GrokBillingError.noCredentials {
            lastStatus = .unauthenticated
            return mutedNoData(now: now, tagged: false)
        } catch GrokBillingError.unauthorized {
            lastStatus = .unauthenticated
            return mutedNoData(now: now, tagged: false)
        } catch {
            return degrade(now: now, error: error)
        }
    }

    private func buildSnapshot(from billing: GrokBillingResponse, now: Date) -> UsageSnapshot {
        let quota = billing.makeQuota()
        var raw: [String: String] = [:]
        if let tier = billing.subscriptionTier { raw["subscriptionTier"] = tier }
        if let period = billing.currentPeriod { raw["currentPeriod"] = period }
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
        if let prepaid = billing.prepaidBalance {
            balance = Decimal(prepaid)
        } else {
            balance = nil
        }

        return UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: balance,
            quota: quota,
            raw: raw,
            quotaWindows: window,
            tooltipLabel: billing.subscriptionTier
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

import Foundation
import os

/// OpenRouter provider actor implementing `UsageProvider`.
///
/// Fetches `GET /api/v1/credits` and `GET /api/v1/key` concurrently via `async let`,
/// applies the D-01..D-05 baseline-delta logic for today's USD cost, and returns
/// a `UsageSnapshot` with quota (or nil for unlimited accounts per ROUTER-03 / D-14).
///
/// Construction pattern for Plan 01.05 composition root:
/// ```swift
/// OpenRouterProvider(
///     client: HTTPOpenRouterClient(http: urlSessionHTTPClient, endpoint: .default, bearer: apiKey, httpReferer: nil, xTitle: "Agents Usage Bar"),
///     cache: fileCacheStore,
///     clock: SystemClock()
/// )
/// ```
public actor OpenRouterProvider: UsageProvider {

    // MARK: - UsageProvider nonisolated constants

    public nonisolated let id = ProviderID.openrouter
    public nonisolated let displayName = "OpenRouter"
    public nonisolated let capabilities = ProviderCapabilities(
        hasQuota: true,
        hasCost: true,
        hasTokens: false,
        isLocal: false
    )

    // MARK: - Actor-isolated state

    private let client: any OpenRouterClient
    private let cache: any CacheStore
    private let clock: any Clock
    private let logger = AppLogger.logger(category: "openrouter")
    private var lastStatus: ProviderStatus = .error(ProviderError.notYetFetched)

    // MARK: - Init

    public init(client: any OpenRouterClient, cache: any CacheStore, clock: any Clock) {
        self.client = client
        self.cache = cache
        self.clock = clock
    }

    // MARK: - UsageProvider

    public func status() -> ProviderStatus {
        lastStatus
    }

    public func fetch(now: Date) async throws -> UsageSnapshot {
        do {
            // Concurrent fetch — both endpoints in parallel (RESEARCH.md §Composition)
            async let credits = client.getCredits()
            async let key = client.getKey()
            let (c, k) = try await (credits, key)

            // MARK: Baseline-delta logic (D-01..D-05)

            let baseline = cache.baseline(for: id, on: now)
            let today = TodayHelper.formatYYYYMMDD(now)
            let costToday: Double

            if let b = baseline, b.date == today {
                if c.data.totalUsage >= b.value {
                    // Normal same-day positive delta (D-01)
                    costToday = c.data.totalUsage - b.value
                } else {
                    // D-04: negative delta — refund or manual reset
                    logger.warning("OpenRouter baseline reset (negative delta): \(b.value, privacy: .public) → \(c.data.totalUsage, privacy: .public)")
                    costToday = 0
                }
            } else {
                // D-03 cold launch OR D-05 day boundary crossed — today = 0 until next poll
                costToday = 0
            }

            // Persist/update baseline (D-02, D-04, D-05 all handled inside CacheStore)
            cache.maintainBaseline(for: id, now: now, currentValue: c.data.totalUsage)

            // MARK: Quota construction (D-14 / ROUTER-03)

            // nil limit → unlimited account → quota = nil → engine emits no decision
            let quota: Quota? = k.data.limit.map { lim in
                Quota(
                    used: k.data.usage,
                    limit: lim,
                    remaining: k.data.limitRemaining ?? max(0, lim - k.data.usage)
                )
            }

            // MARK: Balance (ROUTER-03)

            let balance = c.data.totalCredits - c.data.totalUsage

            // MARK: Snapshot assembly

            let snap = UsageSnapshot(
                providerID: id,
                asOf: now,
                tokensToday: nil,                       // OpenRouter exposes no token count
                costTodayUSD: Decimal(costToday),
                balanceUSD: Decimal(balance),
                quota: quota,
                raw: [:]
            )

            lastStatus = .ok(lastSuccess: now)
            return snap

        } catch {
            // Classify error and update status
            let providerError = ProviderError.from(error)
            lastStatus = .error(providerError)
            logger.error("fetch failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

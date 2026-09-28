import Foundation
import os

/// Ollama Cloud monthly included usage (`ollama-cloud` row, SPEC G1).
///
/// Polls `GET ollama.com/api/usage` every tick and `POST /api/me` until the plan
/// is known. Maps `limits.monthly.usage` to one `mo` quota window; everything else
/// is optional context (tooltip + `raw`). Failures throw so `AggregateStore`
/// applies the shared stale/error handling (V18); a rejected credential throws
/// `.auth` with a fix-it hint and never falls back to another credential (V5).
public actor OllamaCloudProvider: UsageProvider {

    public nonisolated let id = ProviderID.ollamaCloud
    public nonisolated let displayName = "Ollama Cloud"
    /// V9: quota only — never contributes to today's cost/token totals.
    public nonisolated let capabilities = ProviderCapabilities(
        hasQuota: true,
        hasCost: false,
        hasTokens: false,
        isLocal: false
    )

    static let windowName = "mo"
    static let windowDuration: TimeInterval = 30 * 24 * 3600

    private let client: OllamaCloudClient
    private let billingDay: Int?
    private let timeZone: TimeZone
    private let logger = AppLogger.logger(category: "ollama-cloud")
    private var lastStatus: ProviderStatus = .error(ProviderError.notYetFetched)
    private var plan: String?

    public init(client: OllamaCloudClient, billingDay: Int?, timeZone: TimeZone = .current) {
        self.client = client
        self.billingDay = billingDay
        self.timeZone = timeZone
    }

    public func status() -> ProviderStatus {
        lastStatus
    }

    public func fetch(now: Date) async throws -> UsageSnapshot {
        let usage: OllamaUsageResponse
        do {
            usage = try await client.usage(now: now)
        } catch {
            let providerError = classify(error)
            lastStatus = .error(providerError)
            logger.error("usage fetch failed: \(providerError.kind.rawValue, privacy: .public) \(providerError.message, privacy: .public)")
            throw providerError
        }

        // V17: plan once per launch; best-effort, retried next tick until it lands.
        if plan == nil {
            plan = try? await client.plan(now: now)
        }

        let snap = Self.snapshot(
            usage: usage,
            plan: plan,
            credential: client.credential,
            billingDay: billingDay,
            now: now,
            timeZone: timeZone
        )
        lastStatus = .ok(lastSuccess: now)
        return snap
    }

    private func classify(_ error: Error) -> ProviderError {
        if let http = error as? HTTPError, http.status == 401 || http.status == 403 {
            return ProviderError(kind: .auth, message: client.credential.rejectedHint)
        }
        return ProviderError.from(error)
    }

    // MARK: - Mapping (pure; V7, V8, V10, V13, V14)

    static func snapshot(
        usage: OllamaUsageResponse,
        plan: String?,
        credential: OllamaCloudCredential,
        billingDay: Int?,
        now: Date,
        timeZone: TimeZone
    ) -> UsageSnapshot {
        let window = usage.limits?.monthly?.usage.map { fraction in
            QuotaWindow(
                name: windowName,
                utilization: min(max(fraction, 0), 1),
                resetsAt: nextReset(billingDay: billingDay, after: now, timeZone: timeZone),
                duration: windowDuration
            )
        }
        let ownSpend = usage.activity?.cost.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }

        var raw = ["credentialSource": credential.sourceKey]
        var tooltip: [String] = []
        if let plan {
            raw["plan"] = plan
            tooltip.append(plan.capitalized)
        }
        if let ownSpend {
            raw["ownSpendLast4WeeksUSD"] = "\(ownSpend)"
            tooltip.append("your last 4 weeks: $\(String(format: "%.2f", NSDecimalNumber(decimal: ownSpend).doubleValue))")
        }
        tooltip.append(credential.sourceLabel)

        return UsageSnapshot(
            providerID: .ollamaCloud,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: window?.asQuota,
            raw: raw,
            quotaWindows: window.map { [$0] },
            tooltipLabel: tooltip.joined(separator: "\n")
        )
    }

    /// Next local midnight on day `billingDay` strictly after `now`; the day clamps
    /// to the month's last day. Gregorian calendar regardless of the user's calendar
    /// (Buddhist-calendar gotcha). `nil` when `billingDay` is unset/out of range.
    static func nextReset(billingDay: Int?, after now: Date, timeZone: TimeZone) -> Date? {
        guard let billingDay, (1...31).contains(billingDay) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard var monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) else {
            return nil
        }
        for _ in 0..<2 {
            guard let days = calendar.range(of: .day, in: .month, for: monthStart),
                  let candidate = calendar.date(byAdding: .day, value: min(billingDay, days.count) - 1, to: monthStart)
            else { return nil }
            if candidate > now { return candidate }
            guard let next = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return nil }
            monthStart = next
        }
        return nil
    }
}

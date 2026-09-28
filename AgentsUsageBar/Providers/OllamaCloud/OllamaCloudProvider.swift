import Foundation
import os

/// Ollama Cloud monthly included usage (`ollama-cloud` row, SPEC G1).
///
/// Every fetch re-reads the `[ollama]` config and the `ollama signin` device key, so
/// a fixed key, a new `billing_day` or a rotated device key applies on the next
/// poll, and key bytes live only for the fetch (V4, V6). Polls `GET /api/usage`
/// every tick and, after a successful usage call, `POST /api/me` until one call
/// succeeds for the current credential (V17). Failures throw so `AggregateStore` applies the shared
/// stale/error handling (V18); a rejected credential throws `.auth` with a fix-it
/// hint and never falls back to another credential (V5).
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

    /// No `duration`: the API reports none and calendar months are not fixed-length;
    /// compact would otherwise label the row `30d` instead of `mo` (SPEC V24).
    static let windowName = "mo"
    static let noCredentialHint = "run ollama signin or set OLLAMA_API_KEY"

    private let http: any HTTPClient
    private let loadConfig: @Sendable () -> OllamaCloudConfig
    private let loadDevice: @Sendable () -> OllamaDeviceSigner?
    private let baseURL: URL
    private let timeZone: TimeZone
    private let logger = AppLogger.logger(category: "ollama-cloud")
    private var lastStatus: ProviderStatus = .error(ProviderError.notYetFetched)
    private var plan: String?
    private var planFetched = false
    /// Credential source the cached plan belongs to; a change re-fetches the plan.
    private var planSource: String?

    public init(
        http: any HTTPClient,
        loadConfig: @escaping @Sendable () -> OllamaCloudConfig,
        loadDevice: @escaping @Sendable () -> OllamaDeviceSigner? = { OllamaDeviceSigner.load() },
        baseURL: URL = OllamaCloudClient.defaultBaseURL,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.http = http
        self.loadConfig = loadConfig
        self.loadDevice = loadDevice
        self.baseURL = baseURL
        self.timeZone = timeZone
    }

    public func status() -> ProviderStatus {
        lastStatus
    }

    public func fetch(now: Date) async throws -> UsageSnapshot {
        let config = loadConfig()
        guard let credential = OllamaCloudCredential.resolve(config: config, loadDevice: loadDevice) else {
            throw fail(ProviderError(kind: .auth, message: Self.noCredentialHint), source: "none")
        }
        if credential.sourceKey != planSource {
            plan = nil
            planFetched = false
            planSource = credential.sourceKey
        }
        let client = OllamaCloudClient(http: http, credential: credential, baseURL: baseURL)

        let usage: OllamaUsageResponse
        do {
            usage = try await client.usage(now: now)
        } catch {
            throw fail(classify(error, credential: credential), source: credential.sourceKey)
        }
        // After usage succeeds, so a rejected credential never sends a second request.
        if case .success(let fetched)? = await Self.fetchPlan(client, now: now, needed: !planFetched) {
            plan = fetched
            planFetched = true
        }

        let snap = Self.snapshot(
            usage: usage,
            plan: plan,
            credential: credential,
            billingDay: config.billingDay,
            now: now,
            timeZone: timeZone
        )
        lastStatus = .ok(lastSuccess: now)
        return snap
    }

    /// `nil` when the plan is already known; otherwise the `/api/me` outcome. A 2xx
    /// without `Plan` still counts as fetched (no re-POST every tick).
    private static func fetchPlan(_ client: OllamaCloudClient, now: Date, needed: Bool) async -> Result<String?, Error>? {
        guard needed else { return nil }
        do {
            return .success(try await client.plan(now: now))
        } catch {
            return .failure(error)
        }
    }

    private func fail(_ error: ProviderError, source: String) -> ProviderError {
        lastStatus = .error(error)
        logger.error("usage fetch failed (\(source, privacy: .public)): \(error.kind.rawValue, privacy: .public) \(error.message, privacy: .private)")
        return error
    }

    private func classify(_ error: Error, credential: OllamaCloudCredential) -> ProviderError {
        if let http = error as? HTTPError, http.status == 401 || http.status == 403 {
            return ProviderError(kind: .auth, message: credential.rejectedHint)
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
                resetsAt: nextReset(billingDay: billingDay, after: now, timeZone: timeZone)
            )
        }
        // `Decimal(string:)` accepts a numeric prefix ("1.5abc" → 1.5); require the whole
        // string to be a number so garbage is omitted, not misread (V10).
        let ownSpend = usage.activity?.cost.flatMap { cost in
            Double(cost) == nil ? nil : Decimal(string: cost, locale: Locale(identifier: "en_US_POSIX"))
        }

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

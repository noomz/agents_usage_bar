import Foundation
import os

// MARK: - CodexOAuthClientProtocol
//
// Narrow protocol seam for the wham/usage fetch. `CodexOAuthClient` conforms
// via the extension below. Tests inject a stub (`FakeCodexOAuthClient`) or
// `nil` without touching the concrete actor. Mirrors the Phase 2 pattern at
// `ClaudeOAuthClientProtocol` in ClaudeJSONLProvider.swift.

public protocol CodexOAuthClientProtocol: Actor {
    func fetchUsage() async throws -> CodexUsageResponse
    /// Quota for a discovered login. `accountId` nil omits `ChatGPT-Account-Id`.
    func fetchUsage(token: Secret, accountId: String?) async throws -> CodexUsageResponse
}

extension CodexOAuthClient: CodexOAuthClientProtocol {}

// MARK: - CodexRolloutScannerFactory
//
// Each `fetch(now:)` call constructs a scanner pinned to the current wall
// clock — today + yesterday math depends on `now`. Tests inject a factory
// that points at a fixture tempdir root. Production callers pass a factory
// that uses `CodexRoots.defaultRoot`.

public typealias CodexRolloutScannerFactory = @Sendable (Date) -> CodexRolloutScanner

// MARK: - CodexJSONLProvider
//
// The user-visible Codex provider. Composes the Wave 1 primitives:
//   - Plan 03-01: CodexRolloutScanner + CodexRolloutParser
//   - Plan 03-02: CodexModelPricing
//   - Plan 03-03: CodexCredentialLoader + CodexOAuthClient
// Plus the Phase 2 byte-offset cache discipline (TranscriptReader + CacheStore
// batched setTranscriptOffsets API — commit 378c553 / STATE #43).
//
// Algorithm (RESEARCH §"Codex OAuth Fallback State Machine"):
//   0. Two or more subscription logins: rollout tokens and cost only, then one
//      independent wham/usage call per login. One failure does not throw.
//   1. Scan rollouts (today + yesterday) via CodexRolloutScanner.
//   2. If rollout files exist:
//      a. Read deltas via TranscriptReader (fan-out via withThrowingTaskGroup)
//         to maintain the byte-offset cache invariant. The reader's per-line
//         Claude decoder is NOT consumed — Codex events go through the
//         CodexRolloutParser fold instead.
//      b. Fold across all files via CodexRolloutParser.lastTokenCount(in:).
//      c. Single batched cache.setTranscriptOffsets(...) write (STATE #43).
//      d. If parser returned a token_count event → buildSnapshot(fromRollout:).
//         When that event has no live quota windows (CLIProxy and other custom
//         model providers write null primary/secondary), overlay quota from
//         wham/usage and keep the rollout's tokens and cost.
//         Else fall through to step 3 (OAuth fallback).
//   3. OAuth fallback (D-02 — full snapshot fires ONLY when rollout yielded no event):
//      a. If oauth == nil → mutedNoData (D-03).
//      b. fetch wham/usage:
//         - .noCredentials / .unauthorized → mutedNoData (terminal, neutral UX)
//         - .usageEndpointFailed → rethrow (POLL-05 breaker handles backoff)
//         - success → buildSnapshot(fromOAuth:)
//
// Invariants enforced:
//   - D-02: rollout wins; OAuth is fallback-only (verified by test N).
//   - D-03: muted "No data yet" is a NEUTRAL snapshot, not an error.
//   - D-05: primary quota = max(primary, secondary) / 100 in BOTH paths.
//   - D-15: plan_type / planType lands in UsageSnapshot.tooltipLabel.
//   - D-12: NO new CircuitBreaker — POLL-05 at AggregateStore is sufficient.
//   - Pitfall 11: use the cumulative session-total token usage, NOT the
//     per-request delta — see Plan 03-01 CodexRolloutEvent.TokenInfo docs.
//   - Pitfall 5: malformed last lines tolerated by parser, propagated here.
//   - SEC-01/02: no token/credential string ever logged.
public actor CodexJSONLProvider: UsageProvider {

    // MARK: - UsageProvider nonisolated constants

    public nonisolated let id: ProviderID = .codex
    public nonisolated let displayName: String = "Codex"
    public nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: true,
        hasCost: true,
        hasTokens: true,
        isLocal: false
    )

    // MARK: - Actor-isolated state

    private let scannerFactory: CodexRolloutScannerFactory
    private let reader: TranscriptReader
    private let pricing: CodexModelPricing?
    private let oauth: (any CodexOAuthClientProtocol)?
    private let cache: any CacheStore
    private let clock: any Clock
    /// Subscription logins. Default is empty so tests do not read the real home directory.
    /// Production passes a closure that reads disk on every fetch.
    private let logins: @Sendable () -> [CodexDiscoveredLogin]

    private let logger = AppLogger.logger(category: "codex")
    private var lastStatus: ProviderStatus = .error(ProviderError.notYetFetched)

    // MARK: - Init

    /// Designated initialiser — all dependencies injected for testability.
    ///
    /// - Parameters:
    ///   - scannerFactory: Closure that builds a `CodexRolloutScanner` for a
    ///     given `now`. Production passes `{ CodexRolloutScanner(now: $0) }`.
    ///     Tests inject a closure that overrides the scanner root with a
    ///     fixture tempdir.
    ///   - reader: `TranscriptReader` actor — reused verbatim from Phase 2 P-01
    ///     for its byte-offset resume invariant.
    ///   - pricing: `CodexModelPricing` cascade-lookup. May be `nil` when the
    ///     bundled pricing table failed to load (graceful degrade — costs render
    ///     as `nil` rather than crashing).
    ///   - oauth: Optional OAuth-fallback client. Pass `nil` for tests that
    ///     exercise rollout-only paths, or in production when OAuth is
    ///     intentionally disabled.
    ///   - cache: `CacheStore` — used solely for the batched transcript-offset
    ///     map (`allTranscriptOffsets` / `setTranscriptOffsets`).
    ///   - clock: Injected for parity with Phase 2 providers; not used in the
    ///     fetch body (fetch's `now` parameter is authoritative).
    ///   - logins: Enabled subscription logins. Empty keeps today's single path,
    ///     including an API-key `auth.json` that is not itself a login.
    init(
        scannerFactory: @escaping CodexRolloutScannerFactory,
        reader: TranscriptReader,
        pricing: CodexModelPricing?,
        oauth: (any CodexOAuthClientProtocol)?,
        cache: any CacheStore,
        clock: any Clock,
        logins: @escaping @Sendable () -> [CodexDiscoveredLogin] = { [] }
    ) {
        self.scannerFactory = scannerFactory
        self.reader = reader
        self.pricing = pricing
        self.oauth = oauth
        self.cache = cache
        self.clock = clock
        self.logins = logins
    }

    // MARK: - UsageProvider

    public func status() -> ProviderStatus {
        lastStatus
    }

    public func fetch(now: Date) async throws -> UsageSnapshot {
        let discovered = logins()
        let rollout = await readRollout(now: now)

        // Two or more subscription logins share one row. Rollout tokens and
        // cost stay on the header. Each login's quota is its own wham/usage.
        if discovered.count >= 2 {
            let snap = await multiLoginSnapshot(logins: discovered, rollout: rollout, now: now)
            lastStatus = .ok(lastSuccess: now)
            return snap
        }

        // One subscription login stays a single row. Its token is what wham/usage
        // uses for a windowless overlay and for the no-rollout fallback. Live
        // rollout windows still win, below. Zero logins keep today's path.
        let singleLogin = discovered.count == 1 ? discovered[0] : nil

        if let snap = rollout {
            if snap.quotaWindows == nil || snap.quotaWindows?.isEmpty == true,
               let overlaid = await overlayQuotaFromOAuth(onto: snap, now: now, login: singleLogin) {
                lastStatus = .ok(lastSuccess: now)
                return overlaid
            }
            lastStatus = .ok(lastSuccess: now)
            return snap
        }

        // STEP 3 — OAuth fallback (D-02 — only when rollout yielded nothing).
        guard let oauth else {
            lastStatus = .unauthenticated
            return mutedNoData(now: now)
        }

        do {
            let response: CodexUsageResponse
            if let singleLogin {
                response = try await oauth.fetchUsage(
                    token: singleLogin.accessToken,
                    accountId: singleLogin.accountId
                )
            } else {
                response = try await oauth.fetchUsage()
            }
            let snap = buildSnapshot(fromOAuth: response, now: now)
            lastStatus = .ok(lastSuccess: now)
            return snap
        } catch CodexOAuthError.noCredentials {
            lastStatus = .unauthenticated
            return mutedNoData(now: now)
        } catch CodexOAuthError.unauthorized(let status) {
            // 401/403 are terminal until user re-authenticates via Codex CLI —
            // D-03 muted "No data yet" UX, NOT a red error row.
            logger.notice("oauth unauthorized \(status, privacy: .public) — degrading to muted no-data")
            lastStatus = .unauthenticated
            return mutedNoData(now: now)
        } catch CodexOAuthError.usageEndpointFailed(let status) {
            // 429 / 5xx — propagate so AggregateStore-level POLL-05 breaker
            // can increment per D-12. The breaker handles backoff; this actor
            // does not re-add a per-provider breaker.
            logger.notice("oauth endpoint failed \(status, privacy: .public) — propagating")
            let err = ProviderError(kind: .http, message: "HTTP \(status)")
            lastStatus = .error(err)
            throw CodexOAuthError.usageEndpointFailed(status: status)
        }
        // .fileFormat and any unexpected error are rethrown — neither path is
        // expected from the loader's nil-on-fail contract; the catch-by-case
        // shape above is intentionally exhaustive over the CodexOAuthError enum
        // we care about.
    }

    /// Today's rollout snapshot, or nil when no `token_count` event exists.
    ///
    /// Still advances the transcript-offset cache when files are present.
    /// Callers with two or more logins keep tokens and cost and ignore windows.
    private func readRollout(now: Date) async -> UsageSnapshot? {
        let scanner = scannerFactory(now)
        let rolloutFiles = scanner.rolloutFiles()
        guard !rolloutFiles.isEmpty else { return nil }

        let priorOffsets = cache.allTranscriptOffsets()
        var newOffsets: [String: TranscriptOffset] = [:]

        do {
            try await withThrowingTaskGroup(
                of: (URL, TranscriptReader.ReadResult).self
            ) { group in
                for fileURL in rolloutFiles {
                    let key = fileURL.absoluteString
                    let priorOffset = priorOffsets[key]?.byteOffset ?? 0
                    let priorMTime = priorOffsets[key]?.lastModified
                    group.addTask { [reader] in
                        let result = try await reader.readDelta(
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
                }
            }
        } catch {
            logger.notice("reader pass partial-failure: \(error.localizedDescription, privacy: .public)")
        }

        cache.setTranscriptOffsets(Array(newOffsets.values))

        guard let pick = CodexRolloutParser.lastTokenCount(in: rolloutFiles) else {
            return nil
        }
        return buildSnapshot(fromRollout: pick.event, fileURL: pick.fileURL, now: now)
    }

    /// One snapshot for every enabled login. A failed `wham/usage` leaves that
    /// child unavailable and does not cancel the others.
    private func multiLoginSnapshot(
        logins discovered: [CodexDiscoveredLogin],
        rollout: UsageSnapshot?,
        now: Date
    ) async -> UsageSnapshot {
        let responses = await quotas(for: discovered)
        let failed = discovered.count - responses.count
        if failed > 0 {
            logger.notice("codex accounts: \(failed, privacy: .public) wham/usage call(s) failed")
        }

        var planTypes: [String: String] = [:]
        for (index, login) in discovered.enumerated() {
            if let plan = responses[index]?.planType {
                planTypes[login.accountId ?? ""] = plan
            }
        }
        let labeled = CodexLoginDiscovery.labeled(discovered, planTypes: planTypes)
        let accounts = labeled.map { item in
            let response = discovered.firstIndex(of: item.login).flatMap { responses[$0] }
            return accountUsage(name: item.label, response: response)
        }
        let maxPrimary = accounts.compactMap { account in
            account.quotaWindows?.first { $0.name == "primary" }?.utilization
        }.max()
        let headerQuota = maxPrimary.map { fraction in
            Quota(used: fraction, limit: 1.0, remaining: max(0.0, 1.0 - fraction))
        }
        return UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: rollout?.tokensToday,
            costTodayUSD: rollout?.costTodayUSD,
            balanceUSD: nil,
            quota: headerQuota,
            raw: ["source": "codex-accounts"],
            quotaWindows: nil,
            tooltipLabel: nil,
            accounts: accounts
        )
    }

    private func quotas(for discovered: [CodexDiscoveredLogin]) async -> [Int: CodexUsageResponse] {
        guard let client = oauth else { return [:] }
        return await withTaskGroup(
            of: (Int, CodexUsageResponse?).self,
            returning: [Int: CodexUsageResponse].self
        ) { group in
            for (index, login) in discovered.enumerated() {
                let token = login.accessToken
                let accountId = login.accountId
                group.addTask {
                    do {
                        let response = try await client.fetchUsage(token: token, accountId: accountId)
                        return (index, response)
                    } catch {
                        return (index, nil)
                    }
                }
            }
            var found: [Int: CodexUsageResponse] = [:]
            for await (index, response) in group {
                if let response {
                    found[index] = response
                }
            }
            return found
        }
    }

    /// Primary fraction only. A missing primary window leaves `quota` nil even
    /// when a secondary window is present.
    private func accountUsage(
        name: String,
        response: CodexUsageResponse?
    ) -> UsageSnapshot.AccountUsage {
        guard let response else {
            return UsageSnapshot.AccountUsage(
                name: name,
                costTodayUSD: nil,
                quota: nil,
                quotaWindows: nil
            )
        }
        var windows: [QuotaWindow] = []
        let primary = response.rateLimit?.primaryWindow
        let primaryFraction = primary?.usedPercent.map { Double($0) / 100.0 }
        if let primary {
            windows.append(QuotaWindow(
                name: "primary",
                utilization: primaryFraction,
                resetsAt: primary.resetDate(),
                duration: primary.limitWindowSeconds.map(TimeInterval.init)
            ))
        }
        if let secondary = response.rateLimit?.secondaryWindow {
            windows.append(QuotaWindow(
                name: "secondary",
                utilization: secondary.usedPercent.map { Double($0) / 100.0 },
                resetsAt: secondary.resetDate(),
                duration: secondary.limitWindowSeconds.map(TimeInterval.init)
            ))
        }
        let quota = primaryFraction.map { fraction in
            Quota(used: fraction, limit: 1.0, remaining: max(0.0, 1.0 - fraction))
        }
        return UsageSnapshot.AccountUsage(
            name: name,
            costTodayUSD: nil,
            quota: quota,
            quotaWindows: windows.isEmpty ? nil : windows
        )
    }

    /// Quota for a rollout that recorded tokens but no live windows.
    ///
    /// CLIProxy (`model_provider = "cliproxy"`, `requires_openai_auth = false`)
    /// writes `token_count` events whose `primary` and `secondary` are JSON
    /// null. Keeping yesterday's exhausted window shows 100% after the reset.
    /// wham/usage is the live account quota; tokens and cost stay on the rollout.
    /// A fetch failure leaves the rollout row in place (spend still renders).
    private func overlayQuotaFromOAuth(
        onto rollout: UsageSnapshot,
        now: Date,
        login: CodexDiscoveredLogin?
    ) async -> UsageSnapshot? {
        guard let oauth else { return nil }
        let quotaSnap: UsageSnapshot
        do {
            let response: CodexUsageResponse
            if let login {
                response = try await oauth.fetchUsage(token: login.accessToken, accountId: login.accountId)
            } else {
                response = try await oauth.fetchUsage()
            }
            quotaSnap = buildSnapshot(fromOAuth: response, now: now)
        } catch {
            logger.notice("windowless rollout — wham/usage overlay failed")
            return nil
        }
        guard quotaSnap.quota != nil || quotaSnap.quotaWindows?.isEmpty == false else {
            return nil
        }
        return UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: rollout.tokensToday,
            costTodayUSD: rollout.costTodayUSD,
            balanceUSD: quotaSnap.balanceUSD ?? rollout.balanceUSD,
            quota: quotaSnap.quota,
            raw: [
                "source": "rollout+wham-usage",
                "fileURL": rollout.raw["fileURL"] ?? "",
            ],
            quotaWindows: quotaSnap.quotaWindows,
            tooltipLabel: quotaSnap.tooltipLabel ?? rollout.tooltipLabel
        )
    }

    // MARK: - Snapshot builders

    /// Builds a UsageSnapshot from a local rollout `token_count` event.
    ///
    /// Pitfall 11 invariant: uses the cumulative session-total token usage
    /// (emitted on every token_count event), NOT the per-request delta variant
    /// which would under-count the session aggregate.
    private func buildSnapshot(
        fromRollout event: CodexRolloutEvent,
        fileURL: URL,
        now: Date
    ) -> UsageSnapshot {
        // Tokens — total_token_usage.total_tokens.
        let totalTokenUsage = event.payload.info?.totalTokenUsage
        let tokensToday = totalTokenUsage?.totalTokens

        // Cost — pricing is best-effort; modelID is nil today (rollout
        // token_count events don't carry model IDs — see Plan 03-02 SUMMARY).
        let costTodayUSD: Decimal?
        if let pricing, let usage = totalTokenUsage {
            costTodayUSD = pricing.cost(
                inputTokens: usage.inputTokens,
                cachedInputTokens: usage.cachedInputTokens,
                outputTokens: usage.outputTokens,
                reasoningOutputTokens: usage.reasoningOutputTokens ?? 0,
                modelID: nil
            )
        } else {
            costTodayUSD = nil
        }

        // Quota windows — primary + secondary from rate_limits.
        var windows: [QuotaWindow] = []
        var primaryFrac: Double?
        var secondaryFrac: Double?

        if let primary = event.payload.rateLimits?.primary {
            let frac = Double(primary.usedPercent) / 100.0
            primaryFrac = frac
            windows.append(QuotaWindow(
                name: "primary",
                utilization: frac,
                resetsAt: primary.resetsAtDate(now: now),
                duration: TimeInterval(primary.windowMinutes * 60)
            ))
        }
        if let secondary = event.payload.rateLimits?.secondary {
            let frac = Double(secondary.usedPercent) / 100.0
            secondaryFrac = frac
            windows.append(QuotaWindow(
                name: "secondary",
                utilization: frac,
                resetsAt: secondary.resetsAtDate(now: now),
                duration: TimeInterval(secondary.windowMinutes * 60)
            ))
        }

        let quotaWindows: [QuotaWindow]? = windows.isEmpty ? nil : windows

        // Primary quota fraction (D-05): max(primary, secondary) / 100.
        let primaryQuota: Quota?
        if let maxFrac = [primaryFrac, secondaryFrac].compactMap({ $0 }).max() {
            primaryQuota = Quota(
                used: maxFrac,
                limit: 1.0,
                remaining: max(0.0, 1.0 - maxFrac)
            )
        } else {
            primaryQuota = nil
        }

        // D-15: surface plan_type via tooltipLabel.
        let tooltipLabel = event.payload.rateLimits?.planType

        // Balance (best-effort Decimal-parse of the rollout's credit balance).
        let balanceUSD: Decimal?
        if let balanceStr = event.payload.rateLimits?.credits?.balance {
            balanceUSD = Decimal(string: balanceStr)
        } else {
            balanceUSD = nil
        }

        return UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: tokensToday,
            costTodayUSD: costTodayUSD,
            balanceUSD: balanceUSD,
            quota: primaryQuota,
            raw: ["source": "rollout", "fileURL": fileURL.lastPathComponent],
            quotaWindows: quotaWindows,
            tooltipLabel: tooltipLabel
        )
    }

    /// Builds a UsageSnapshot from a successful wham/usage response.
    ///
    /// RESEARCH note: wham/usage carries NO total_token_usage — tokensToday and
    /// costTodayUSD are both nil on this path. The row still renders quota
    /// bars + reset countdowns from the response's rate_limit windows.
    private func buildSnapshot(
        fromOAuth response: CodexUsageResponse,
        now: Date
    ) -> UsageSnapshot {
        var windows: [QuotaWindow] = []
        var primaryFrac: Double?
        var secondaryFrac: Double?

        if let primary = response.rateLimit?.primaryWindow {
            let frac = primary.usedPercent.map { Double($0) / 100.0 }
            primaryFrac = frac
            windows.append(QuotaWindow(
                name: "primary",
                utilization: frac,
                resetsAt: primary.resetDate(),
                duration: primary.limitWindowSeconds.map(TimeInterval.init)
            ))
        }
        if let secondary = response.rateLimit?.secondaryWindow {
            let frac = secondary.usedPercent.map { Double($0) / 100.0 }
            secondaryFrac = frac
            windows.append(QuotaWindow(
                name: "secondary",
                utilization: frac,
                resetsAt: secondary.resetDate(),
                duration: secondary.limitWindowSeconds.map(TimeInterval.init)
            ))
        }

        let quotaWindows: [QuotaWindow]? = windows.isEmpty ? nil : windows

        // D-05: max(primary, secondary) / 100 — same invariant as rollout path.
        let primaryQuota: Quota?
        if let maxFrac = [primaryFrac, secondaryFrac].compactMap({ $0 }).max() {
            primaryQuota = Quota(
                used: maxFrac,
                limit: 1.0,
                remaining: max(0.0, 1.0 - maxFrac)
            )
        } else {
            primaryQuota = nil
        }

        // D-15: surface planType via tooltipLabel.
        let tooltipLabel = response.planType

        // Balance — wham/usage credits.balance (best-effort).
        let balanceUSD: Decimal?
        if let balanceStr = response.credits?.balance {
            balanceUSD = Decimal(string: balanceStr)
        } else {
            balanceUSD = nil
        }

        return UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: nil,        // wham/usage has no token count
            costTodayUSD: nil,        // cannot compute cost without rollout tokens
            balanceUSD: balanceUSD,
            quota: primaryQuota,
            raw: ["source": "oauth-wham-usage"],
            quotaWindows: quotaWindows,
            tooltipLabel: tooltipLabel
        )
    }

    /// D-03 "No data yet" muted UX — neutral, NOT an error.
    ///
    /// Returned when:
    ///   - oauth == nil AND rollout yielded no token_count event
    ///   - oauth threw .noCredentials (no ~/.codex/auth.json)
    ///   - oauth threw .unauthorized (401/403; terminal until re-auth)
    ///
    /// The ProviderRowView reads lastStatus == .unauthenticated and renders a
    /// dimmed row with "Not configured" placeholder (same convention as
    /// OpenRouter without an API key).
    private func mutedNoData(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: ["status": "no-data-yet"],
            quotaWindows: nil,
            tooltipLabel: nil
        )
    }
}

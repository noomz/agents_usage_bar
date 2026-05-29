import Foundation
import os

// MARK: - ClaudeOAuthClientProtocol

/// Narrow protocol seam for the OAuth usage fetch.
///
/// `ClaudeOAuthClient` conforms via the extension below.
/// Tests inject `FakeOAuthClient` (or `nil`) without touching the concrete actor.
public protocol ClaudeOAuthClientProtocol: Actor {
    func getUsage() async throws -> ClaudeUsageResponse
}

extension ClaudeOAuthClient: ClaudeOAuthClientProtocol {}

// MARK: - ClaudeJSONLProvider

/// Headline Claude provider — composes:
/// - `TranscriptReader` (Plan 02.01) — byte-offset JSONL streaming.
/// - `ClaudeModelPricing` (Plan 02.02) — USD cost calculation per record.
/// - `ClaudeOAuthClient` (Plan 02.03) — optional OAuth quota windows.
///
/// Invariants locked by the test suite:
/// - Today filter: `record.timestamp >= TodayHelper.startOfDay(now)` (Pitfall 7 / UI-04).
/// - Cross-file requestID dedup: global `Set<String>` per poll cycle (RESEARCH §A9).
/// - OAuth degrade-to-local-only: any OAuth error → `quotaWindows = nil`, no rethrow.
/// - Per-file byte-offset persisted after each successful fan-out (CLAUDE-02).
/// - Primary quota = `max(fiveHour, sevenDay)` (RESEARCH Open Question 4).
public actor ClaudeJSONLProvider: UsageProvider {

    // MARK: - UsageProvider nonisolated constants

    public nonisolated let id: ProviderID = .claude
    public nonisolated let displayName: String = "Claude Code"
    public nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: true,
        hasCost: true,
        hasTokens: true,
        isLocal: false
    )

    // MARK: - Actor-isolated state

    private let reader: TranscriptReader
    private let scanner: TranscriptDirectoryScanner
    private let pricing: ClaudeModelPricing
    private let oauth: (any ClaudeOAuthClientProtocol)?
    private let cache: any CacheStore
    private let clock: any Clock
    private let roots: [URL]

    /// Plan 02.06 — Pitfall 5 (default decision #4):
    /// A dedicated 3-strike circuit breaker for the `/api/oauth/usage` endpoint that
    /// trips after 3 consecutive 429 responses (persistent for some Claude Max accounts —
    /// GitHub issue #30930 / #31021). The cooldown matches the general POLL-05 breaker
    /// (5 min) so a transient blip recovers quickly while a truly persistent rate-limit
    /// backs off. Threshold 3 (not the general 5) per RESEARCH Pitfall 5.
    private let oauthBreaker: CircuitBreaker = CircuitBreaker(threshold: 3, cooldown: 300)

    private let logger = AppLogger.logger(category: "claude")
    private var lastStatus: ProviderStatus = .error(ProviderError.notYetFetched)

    // MARK: - ISO8601 parsers (Pitfall 3 — dual formatter, fractional first)

    // `nonisolated(unsafe)` safe: ISO8601DateFormatter.date(from:) is thread-safe per Apple docs.
    // We never mutate formatOptions after initialisation.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoNoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Init

    /// Designated initialiser — all dependencies injected for testability.
    ///
    /// - Parameters:
    ///   - reader: `TranscriptReader` actor for byte-offset JSONL streaming.
    ///   - scanner: `TranscriptDirectoryScanner` for mtime-gated file discovery.
    ///   - pricing: `ClaudeModelPricing` for USD cost per record.
    ///   - oauth: Optional OAuth client. Pass `nil` when credentials are absent (degrade-to-local-only).
    ///   - cache: `CacheStore` for persisting per-file `TranscriptOffset` cursors.
    ///   - clock: Clock abstraction (unused in fetch body but wired for future use / testing).
    ///   - roots: Root directories to scan. Production uses `ClaudeRoots.defaultRoots`.
    ///     Tests inject a fresh temp directory.
    public init(
        reader: TranscriptReader,
        scanner: TranscriptDirectoryScanner,
        pricing: ClaudeModelPricing,
        oauth: (any ClaudeOAuthClientProtocol)?,
        cache: any CacheStore,
        clock: any Clock,
        roots: [URL] = ClaudeRoots.defaultRoots
    ) {
        self.reader = reader
        self.scanner = scanner
        self.pricing = pricing
        self.oauth = oauth
        self.cache = cache
        self.clock = clock
        self.roots = roots
    }

    // MARK: - UsageProvider

    public func status() -> ProviderStatus {
        lastStatus
    }

    /// Fetches Claude usage for today.
    ///
    /// Algorithm (see plan 02-04 for rationale):
    /// 1. Compute today's local midnight via `TodayHelper.startOfDay`.
    /// 2. Load all persisted transcript offsets from cache.
    /// 3. Discover candidate JSONL files (mtime gate for efficiency).
    /// 4. Fan-out per-file reads via `withThrowingTaskGroup` (concurrent).
    ///    Concurrently: kick off OAuth fetch via `async let` (degrades to nil on failure).
    /// 5. Apply today filter + requestID dedup inline per record.
    /// 6. Persist new offsets to cache.
    /// 7. Build `quotaWindows` + `primaryQuota` from OAuth result (or nil).
    /// 8. Return `UsageSnapshot`.
    ///
    /// JSONL fan-out errors propagate (rethrow) — plan 02.06 RetryPolicy handles degradation.
    /// OAuth errors are silently swallowed — `quotaWindows == nil` and local data still rendered.
    public func fetch(now: Date) async throws -> UsageSnapshot {
        do {
            let today = TodayHelper.startOfDay(now, calendar: .current)
            let priorOffsets = cache.allTranscriptOffsets()

            // Mtime floor: oldest persisted offset's lastModified - 1s (defensive).
            let scanFloor: Date? = priorOffsets.values.map(\.lastModified).min()
                .map { $0.addingTimeInterval(-1) }
            let candidateFiles = scanner.scanRoots(roots, modifiedSince: scanFloor)

            // 3. Concurrent OAuth fetch (degrades to nil on any error — Pitfall 5).
            //
            // Plan 02.06 — Pitfall 5 / default decision #4:
            // Wrap the OAuth call in a 3-strike circuit breaker keyed to 429 responses on
            // `/api/oauth/usage`. When the breaker is open we skip the call entirely (returns
            // nil → quotaWindows = nil → graceful degrade to local-JSONL-only). Non-429
            // errors do NOT increment the breaker — they are upstream/caller-side issues,
            // not endpoint flakiness.
            async let oauthResultBox: ClaudeUsageResponse? = {
                guard let oauth else { return nil }
                guard await oauthBreaker.canAttempt(now: now) else {
                    logger.notice("oauth circuit breaker open — degrading to local-only")
                    return nil
                }
                do {
                    let response = try await oauth.getUsage()
                    await oauthBreaker.recordSuccess()
                    return response
                } catch ClaudeOAuthError.usageEndpointFailed(status: 429) {
                    await oauthBreaker.recordFailure(now: now)
                    logger.notice("oauth /api/oauth/usage 429; breaker count incremented")
                    return nil
                } catch {
                    // Other errors (refresh failed, no creds, network) do NOT trip the
                    // OAuth-usage breaker — they are upstream issues, not endpoint flakiness.
                    logger.notice(
                        "OAuth degraded: \(String(describing: error), privacy: .public)"
                    )
                    return nil
                }
            }()

            // 4. Per-file fan-out accumulators.
            var newOffsets: [String: TranscriptOffset] = [:]
            var seenRequestIDs: Set<String> = []      // RESEARCH §A9 cross-file dedup
            var todayTokens = 0
            var todayCost: Decimal = 0

            try await withThrowingTaskGroup(
                of: (URL, TranscriptReader.ReadResult).self
            ) { group in
                for fileURL in candidateFiles {
                    let priorOffset = priorOffsets[fileURL.absoluteString]?.byteOffset ?? 0
                    let priorMTime = priorOffsets[fileURL.absoluteString]?.lastModified
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
                    for record in result.records {
                        // Inline today filter (Pitfall 7 / UI-04): Calendar.current local-midnight.
                        guard record.timestamp >= today else { continue }
                        // requestID dedup across all files in one poll cycle (RESEARCH §A9).
                        if let rid = record.requestID {
                            guard seenRequestIDs.insert(rid).inserted else { continue }
                        }
                        todayTokens += record.totalTokens
                        todayCost += pricing.cost(
                            inputTokens: record.inputTokens,
                            outputTokens: record.outputTokens,
                            cacheCreationTokens: record.cacheCreationTokens,
                            cacheReadTokens: record.cacheReadTokens,
                            modelID: record.model
                        )
                    }
                }
            }

            // 5. Persist offsets (partial progress saved even if fan-out partially failed).
            //    Single batch write — per-offset writes would re-encode the entire
            //    envelope each iteration, which is O(N²) on a freshly-seeded cache
            //    with hundreds of transcript files.
            cache.setTranscriptOffsets(Array(newOffsets.values))

            // 6. Build quotaWindows + primary quota from OAuth result.
            let oauthResult = await oauthResultBox
            let quotaWindows: [QuotaWindow]?
            let primaryQuota: Quota?

            if let oauth = oauthResult {
                var windows: [QuotaWindow] = []
                if let fh = oauth.fiveHour {
                    windows.append(QuotaWindow(
                        name: "5h",
                        utilization: fh.utilization.map { $0 / 100.0 },
                        resetsAt: parseISO(fh.resetsAt)
                    ))
                }
                if let sd = oauth.sevenDay {
                    windows.append(QuotaWindow(
                        name: "7d",
                        utilization: sd.utilization.map { $0 / 100.0 },
                        resetsAt: parseISO(sd.resetsAt)
                    ))
                }
                // Bonus per-model windows (included if present).
                if let s = oauth.sevenDaySonnet {
                    windows.append(QuotaWindow(
                        name: "7d-sonnet",
                        utilization: s.utilization.map { $0 / 100.0 },
                        resetsAt: parseISO(s.resetsAt)
                    ))
                }
                if let o = oauth.sevenDayOpus {
                    windows.append(QuotaWindow(
                        name: "7d-opus",
                        utilization: o.utilization.map { $0 / 100.0 },
                        resetsAt: parseISO(o.resetsAt)
                    ))
                }

                quotaWindows = windows.isEmpty ? nil : windows

                // Primary quota = max(fiveHour, sevenDay) [RESEARCH Open Question 4].
                // Bonus windows (sonnet/opus) excluded from the main bar.
                let primaryUtilization = [oauth.fiveHour?.utilization, oauth.sevenDay?.utilization]
                    .compactMap { $0 }.max()
                if let frac = primaryUtilization.map({ $0 / 100.0 }) {
                    primaryQuota = Quota(used: frac, limit: 1.0, remaining: max(0, 1.0 - frac))
                } else {
                    primaryQuota = nil
                }
            } else {
                quotaWindows = nil
                primaryQuota = nil
            }

            // 7. Snapshot assembly.
            let snap = UsageSnapshot(
                providerID: id,
                asOf: now,
                tokensToday: todayTokens,
                costTodayUSD: todayCost,
                balanceUSD: nil,        // Anthropic doesn't expose a balance figure.
                quota: primaryQuota,
                raw: [:],
                quotaWindows: quotaWindows
            )

            lastStatus = .ok(lastSuccess: now)
            return snap

        } catch {
            let providerError = ProviderError.from(error)
            lastStatus = .error(providerError)
            logger.error("fetch failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Private helpers

    /// Parses an ISO8601 timestamp string with or without fractional seconds (Pitfall 3).
    private func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        return Self.isoFractional.date(from: s) ?? Self.isoNoFractional.date(from: s)
    }
}

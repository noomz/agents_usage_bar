import Foundation
import os

// MARK: - ClaudeHookError

/// Errors thrown by `ClaudeHookProvider.fetch(now:)`.
///
/// `ProviderError.from(_:)` maps these to `.unknown` — the UI renders an error row,
/// which is the desired "hook not producing data" signal (feed empty or dir missing —
/// i.e. the hook is not installed or has never fired).
public enum ClaudeHookError: Error, Equatable {
    /// No session payload found in the feed directory — the directory is missing or empty.
    /// A feed that HAS files but is merely idle (>24h) is NOT an error; it yields a
    /// zero snapshot instead (see `fetch(now:)`).
    case noFeedData
}

// MARK: - ClaudeHookProvider

/// Claude usage provider backed by the statusline-tee hook feed (real Claude Code-reported
/// usage + rate limits), as opposed to `ClaudeJSONLProvider` which reconstructs usage from
/// JSONL transcripts and the OAuth usage endpoint.
///
/// Reads captured statusline payloads written by `aub-statusline.sh` into
/// `<feedDir>/<session_id>.json` (see `ClaudeHookPayload`). No network, no JSONL reads,
/// no secrets in this mode.
///
/// Invariants:
/// - Cost: `costTodayUSD` = Σ `cost.total_cost_usd` over session files whose **mtime** falls
///   on today (local midnight via `TodayHelper`). A session spanning midnight is attributed
///   wholly to today — documented limitation (statusline reports cumulative session cost only).
/// - Tokens: always `nil` — the statusline exposes no cumulative token totals
///   (`context_window.*` is occupancy, not a daily total).
/// - Quota: from the **newest** payload (by mtime) that carries `rate_limits`. Windows
///   `"5h"`/`"7d"`, `utilization = used_percentage / 100`, `resetsAt = Date(epoch)`.
/// - Primary quota = `max(fiveHour, sevenDay)` fraction — same rule as
///   `ClaudeJSONLProvider` (RESEARCH Open Question 4).
/// - Empty / missing feed dir → throw `ClaudeHookError.noFeedData` (hook not installed /
///   never fired — actionable error). A feed with files whose newest is older than 24h means
///   the user simply hasn't used Claude Code lately → valid ZERO snapshot (cost 0, quota nil;
///   stale rate limits would mislead), not an error.
/// - Cleanup: session files with mtime older than 48h are deleted during each fetch to bound
///   directory growth.
public actor ClaudeHookProvider: UsageProvider {

    // MARK: - UsageProvider nonisolated constants

    public nonisolated let id: ProviderID = .claude
    public nonisolated let displayName: String = "Claude Code"
    public nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: true,
        hasCost: true,
        hasTokens: true,
        isLocal: false
    )

    // MARK: - Tunables

    /// A feed whose newest payload is older than this yields a zero snapshot (no quota —
    /// stale rate limits would mislead) instead of live data.
    private static let stalenessHorizon: TimeInterval = 24 * 60 * 60

    /// Session files with mtime older than this are deleted during fetch.
    private static let cleanupHorizon: TimeInterval = 48 * 60 * 60

    // MARK: - Actor-isolated state

    /// Directory holding `<session_id>.json` payload files.
    /// Production default: `~/Library/Application Support/AgentsUsageBar/claude-hook/sessions`.
    /// Tests inject a temp directory.
    private let feedDir: URL

    private let logger = AppLogger.logger(category: "claude-hook")
    private var lastStatus: ProviderStatus = .error(ProviderError.notYetFetched)

    // MARK: - Init

    /// - Parameter feedDir: Directory of captured statusline payloads. Defaults to the
    ///   production feed path; tests inject a fresh temp directory.
    public init(feedDir: URL = ClaudeHookProvider.defaultFeedDir) {
        self.feedDir = feedDir
    }

    /// The production feed directory:
    /// `~/Library/Application Support/AgentsUsageBar/claude-hook/sessions`.
    public static var defaultFeedDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("AgentsUsageBar", isDirectory: true)
            .appendingPathComponent("claude-hook", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    // MARK: - UsageProvider

    public func status() -> ProviderStatus {
        lastStatus
    }

    /// Reads the hook feed and returns today's Claude usage snapshot.
    ///
    /// See the type-level invariants for the cost / tokens / quota / cleanup rules.
    /// Throws `ClaudeHookError.noFeedData` only when the feed dir is missing or empty.
    public func fetch(now: Date) async throws -> UsageSnapshot {
        do {
            let today = TodayHelper.startOfDay(now, calendar: .current)
            let fm = FileManager.default

            // Enumerate <feedDir>/*.json with their modification dates.
            let entries: [(url: URL, mtime: Date)]
            do {
                let contents = try fm.contentsOfDirectory(
                    at: feedDir,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                entries = contents.compactMap { url in
                    guard url.pathExtension == "json" else { return nil }
                    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                    guard let mtime else { return nil }
                    return (url, mtime)
                }
            } catch {
                // Missing feed dir (or unreadable) → no data.
                throw ClaudeHookError.noFeedData
            }

            if entries.isEmpty {
                throw ClaudeHookError.noFeedData
            }

            // Staleness gate: files exist but the newest is older than 24h — the user simply
            // hasn't used Claude Code lately. That is a legitimate zero-usage state, not a
            // broken hook: return a zero snapshot (quota nil — stale rate limits mislead).
            let newestMTime = entries.map(\.mtime).max()!
            if now.timeIntervalSince(newestMTime) > Self.stalenessHorizon {
                // Still perform cleanup so a long-idle feed doesn't grow unbounded.
                cleanup(entries: entries, now: now, fileManager: fm)
                let snap = UsageSnapshot(
                    providerID: id,
                    asOf: now,
                    tokensToday: nil,
                    costTodayUSD: 0,
                    balanceUSD: nil,
                    quota: nil,
                    raw: [:],
                    quotaWindows: nil
                )
                lastStatus = .ok(lastSuccess: now)
                return snap
            }

            // Sum today's session costs + track the newest payload carrying rate_limits.
            var costTodayUSD: Decimal = 0
            var sawTodayCost = false
            var newestQuotaMTime: Date?
            var newestQuotaLimits: ClaudeHookPayload.RateLimits?

            for entry in entries.sorted(by: { $0.mtime < $1.mtime }) {
                guard let data = try? Data(contentsOf: entry.url),
                      let payload = try? ClaudeHookPayload.decode(data)
                else { continue }

                if entry.mtime >= today, let usd = payload.cost?.totalCostUsd {
                    costTodayUSD += Self.decimal(fromUSD: usd)
                    sawTodayCost = true
                }

                if let limits = payload.rateLimits,
                   limits.fiveHour != nil || limits.sevenDay != nil {
                    // Iterating oldest→newest means the last assignment wins = newest payload.
                    if newestQuotaMTime == nil || entry.mtime >= newestQuotaMTime! {
                        newestQuotaMTime = entry.mtime
                        newestQuotaLimits = limits
                    }
                }
            }

            // Build quota windows from the newest rate-limited payload.
            let quotaWindows: [QuotaWindow]?
            let primaryQuota: Quota?
            if let limits = newestQuotaLimits {
                var windows: [QuotaWindow] = []
                if let fh = limits.fiveHour {
                    windows.append(QuotaWindow(
                        name: "5h",
                        utilization: fh.usedPercentage.map { $0 / 100.0 },
                        resetsAt: fh.resetsAtDate
                    ))
                }
                if let sd = limits.sevenDay {
                    windows.append(QuotaWindow(
                        name: "7d",
                        utilization: sd.usedPercentage.map { $0 / 100.0 },
                        resetsAt: sd.resetsAtDate
                    ))
                }
                quotaWindows = windows.isEmpty ? nil : windows

                // Primary quota = max(fiveHour, sevenDay) — matches ClaudeJSONLProvider:281-289.
                let primaryUtilization = [limits.fiveHour?.usedPercentage, limits.sevenDay?.usedPercentage]
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

            // Cleanup files older than 48h to bound directory growth.
            cleanup(entries: entries, now: now, fileManager: fm)

            let snap = UsageSnapshot(
                providerID: id,
                asOf: now,
                tokensToday: nil,                                   // statusline has no token totals
                costTodayUSD: sawTodayCost ? costTodayUSD : nil,
                balanceUSD: nil,
                quota: primaryQuota,
                raw: [:],
                quotaWindows: quotaWindows
            )

            lastStatus = .ok(lastSuccess: now)
            return snap

        } catch {
            let providerError = ProviderError.from(error)
            lastStatus = .error(providerError)
            logger.error("hook fetch failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Feed pruning (public — used by the facade in sessionReads mode)

    /// Prunes session files older than the 48h cleanup horizon WITHOUT reading payloads.
    ///
    /// The tee script keeps writing feed files regardless of the selected source, so
    /// `ClaudeSwitchableProvider` calls this on every `.sessionReads` fetch — otherwise a
    /// user who installed the hook but stays on session reads accumulates one file per
    /// session forever. Best-effort; missing feed dir is a no-op.
    public func pruneFeed(now: Date) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: feedDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let entries: [(url: URL, mtime: Date)] = contents.compactMap { url in
            guard url.pathExtension == "json",
                  let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                      .contentModificationDate
            else { return nil }
            return (url, mtime)
        }
        cleanup(entries: entries, now: now, fileManager: fm)
    }

    // MARK: - Private helpers

    /// Deletes session files whose mtime is older than the 48h cleanup horizon.
    /// Best-effort — deletion failures are logged and ignored.
    private func cleanup(entries: [(url: URL, mtime: Date)], now: Date, fileManager fm: FileManager) {
        for entry in entries where now.timeIntervalSince(entry.mtime) > Self.cleanupHorizon {
            do {
                try fm.removeItem(at: entry.url)
            } catch {
                logger.notice("hook cleanup could not remove \(entry.url.lastPathComponent, privacy: .public)")
            }
        }
    }

    /// Converts a client-reported USD `Double` to `Decimal` via a rounded 6-dp string,
    /// avoiding binary-float drift when accumulating many session costs.
    private static func decimal(fromUSD usd: Double) -> Decimal {
        Decimal(string: String(format: "%.6f", usd)) ?? Decimal(usd)
    }
}

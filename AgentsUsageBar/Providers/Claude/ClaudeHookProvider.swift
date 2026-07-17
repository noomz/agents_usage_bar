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
/// Reads captured statusline payloads written by the `aub-statusline*.sh` tee scripts
/// (see `ClaudeHookPayload`). No network, no JSONL reads, no secrets in this mode.
///
/// Account-aware feed layout (one tee install per account — `ClaudeHookInstaller.HookTarget`):
///   `<feedDir>/<session_id>.json`           → account `"default"` (legacy flat layout, a9d9353)
///   `<feedDir>/<account>/<session_id>.json` → account = ccs instance slug
/// All accounts merge into the single Claude row (ProviderID is a fixed enum): cost is the
/// cross-account sum, `quotaWindows` are per-account (named `"<account> 5h"` etc. when ≥2
/// accounts), `quota` = max utilization across accounts (warn when ANY account is near its
/// limit), and `raw["cost.<account>"]` / `raw["quota.<account>"]` feed the row breakdown line.
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

            // Enumerate the feed, account-aware:
            //   <feedDir>/<session>.json          → account "default" (legacy flat layout, a9d9353)
            //   <feedDir>/<account>/<session>.json → account = subdirectory name (ccs instances)
            let entries: [(account: String, url: URL, mtime: Date)]
            do {
                entries = try Self.enumerate(feedDir: feedDir, fileManager: fm)
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

            // Per-account aggregation: today's cost sum + the newest rate_limits per account.
            struct AccountAgg {
                var costToday: Decimal = 0
                var sawTodayCost = false
                var newestQuotaMTime: Date?
                var newestQuotaLimits: ClaudeHookPayload.RateLimits?
            }
            var accounts: [String: AccountAgg] = [:]

            for entry in entries.sorted(by: { $0.mtime < $1.mtime }) {
                guard let data = try? Data(contentsOf: entry.url),
                      let payload = try? ClaudeHookPayload.decode(data)
                else { continue }

                var agg = accounts[entry.account] ?? AccountAgg()

                if entry.mtime >= today, let usd = payload.cost?.totalCostUsd {
                    agg.costToday += Self.decimal(fromUSD: usd)
                    agg.sawTodayCost = true
                }

                if let limits = payload.rateLimits,
                   limits.fiveHour != nil || limits.sevenDay != nil {
                    // Iterating oldest→newest means the last assignment wins = newest payload.
                    if agg.newestQuotaMTime == nil || entry.mtime >= agg.newestQuotaMTime! {
                        agg.newestQuotaMTime = entry.mtime
                        agg.newestQuotaLimits = limits
                    }
                }

                accounts[entry.account] = agg
            }

            // Stable account order: "default" first, then alphabetical (drives window
            // naming, raw keys, and the tooltip/breakdown line).
            let orderedAccounts = accounts.keys.sorted {
                ($0 == "default" ? 0 : 1, $0) < ($1 == "default" ? 0 : 1, $1)
            }
            let isMultiAccount = orderedAccounts.count >= 2

            // Merged cost across accounts (single Claude row — ProviderID is a fixed enum).
            var costTodayUSD: Decimal = 0
            var sawTodayCost = false

            // Per-account quota windows. Single-account feeds keep the plain "5h"/"7d"
            // names (a9d9353 UI back-compat); multi-account feeds prefix the account.
            var windows: [QuotaWindow] = []
            var maxUtilizationPct: Double?
            var raw: [String: String] = [:]
            var breakdownParts: [String] = []

            for account in orderedAccounts {
                guard let agg = accounts[account] else { continue }
                if agg.sawTodayCost {
                    costTodayUSD += agg.costToday
                    sawTodayCost = true
                }

                var accountMaxPct: Double?
                if let limits = agg.newestQuotaLimits {
                    let prefix = isMultiAccount ? "\(account) " : ""
                    if let fh = limits.fiveHour {
                        windows.append(QuotaWindow(
                            name: prefix + "5h",
                            utilization: fh.usedPercentage.map { $0 / 100.0 },
                            resetsAt: fh.resetsAtDate
                        ))
                    }
                    if let sd = limits.sevenDay {
                        windows.append(QuotaWindow(
                            name: prefix + "7d",
                            utilization: sd.usedPercentage.map { $0 / 100.0 },
                            resetsAt: sd.resetsAtDate
                        ))
                    }
                    accountMaxPct = [limits.fiveHour?.usedPercentage, limits.sevenDay?.usedPercentage]
                        .compactMap { $0 }.max()
                    if let pct = accountMaxPct {
                        maxUtilizationPct = max(maxUtilizationPct ?? 0, pct)
                    }
                }

                // raw keys feed the popover breakdown line (ProviderRowView) + debugging.
                if agg.sawTodayCost {
                    raw["cost.\(account)"] = "\(agg.costToday)"
                }
                if let pct = accountMaxPct {
                    raw["quota.\(account)"] = "\(Int(pct.rounded()))%"
                }
                if isMultiAccount, agg.sawTodayCost || accountMaxPct != nil {
                    let usd = agg.sawTodayCost ? agg.costToday : 0
                    var part = "\(account) $\(Self.usdString(usd))"
                    if let pct = accountMaxPct { part += " \(Int(pct.rounded()))%" }
                    breakdownParts.append(part)
                }
            }

            let quotaWindows = windows.isEmpty ? nil : windows

            // Primary quota = max utilization across ALL accounts' 5h/7d windows —
            // conservative: the bar (and threshold notifications) warn when ANY account
            // is near its limit. Single-account: identical to the a9d9353 max(5h,7d) rule.
            let primaryQuota: Quota?
            if let frac = maxUtilizationPct.map({ $0 / 100.0 }) {
                primaryQuota = Quota(used: frac, limit: 1.0, remaining: max(0, 1.0 - frac))
            } else {
                primaryQuota = nil
            }

            let tooltipLabel = breakdownParts.isEmpty ? nil : breakdownParts.joined(separator: " · ")

            // Cleanup files older than 48h to bound directory growth.
            cleanup(entries: entries, now: now, fileManager: fm)

            let snap = UsageSnapshot(
                providerID: id,
                asOf: now,
                tokensToday: nil,                                   // statusline has no token totals
                costTodayUSD: sawTodayCost ? costTodayUSD : nil,
                balanceUSD: nil,
                quota: primaryQuota,
                raw: raw,
                quotaWindows: quotaWindows,
                tooltipLabel: tooltipLabel
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
        guard let entries = try? Self.enumerate(feedDir: feedDir, fileManager: fm) else { return }
        cleanup(entries: entries, now: now, fileManager: fm)
    }

    // MARK: - Private helpers

    /// Account-aware feed enumeration:
    ///   `<feedDir>/<session>.json`           → account `"default"` (legacy flat layout)
    ///   `<feedDir>/<account>/<session>.json` → account = subdirectory name (ccs instances)
    ///
    /// Throws only when `feedDir` itself is unlistable (missing feed → `noFeedData` upstream).
    /// Unreadable account subdirs are skipped best-effort.
    private static func enumerate(
        feedDir: URL,
        fileManager fm: FileManager
    ) throws -> [(account: String, url: URL, mtime: Date)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        let top = try fm.contentsOfDirectory(
            at: feedDir,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var entries: [(account: String, url: URL, mtime: Date)] = []
        for url in top {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                let account = url.lastPathComponent
                guard let children = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for child in children {
                    guard child.pathExtension == "json",
                          let mtime = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?
                              .contentModificationDate
                    else { continue }
                    entries.append((account, child, mtime))
                }
            } else if url.pathExtension == "json", let mtime = values?.contentModificationDate {
                entries.append(("default", url, mtime))
            }
        }
        return entries
    }

    /// Deletes session files whose mtime is older than the 48h cleanup horizon.
    /// Best-effort — deletion failures are logged and ignored.
    private func cleanup(
        entries: [(account: String, url: URL, mtime: Date)],
        now: Date,
        fileManager fm: FileManager
    ) {
        for entry in entries where now.timeIntervalSince(entry.mtime) > Self.cleanupHorizon {
            do {
                try fm.removeItem(at: entry.url)
            } catch {
                logger.notice("hook cleanup could not remove \(entry.url.lastPathComponent, privacy: .public)")
            }
        }
    }

    /// Formats a USD `Decimal` with two fraction digits for the breakdown line.
    private static func usdString(_ value: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: value)
        return String(format: "%.2f", ns.doubleValue)
    }

    /// Converts a client-reported USD `Double` to `Decimal` via a rounded 6-dp string,
    /// avoiding binary-float drift when accumulating many session costs.
    private static func decimal(fromUSD usd: Double) -> Decimal {
        Decimal(string: String(format: "%.6f", usd)) ?? Decimal(usd)
    }
}

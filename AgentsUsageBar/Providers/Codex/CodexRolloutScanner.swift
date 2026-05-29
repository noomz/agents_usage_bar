import Foundation
import os

/// Walks `~/.codex/sessions/YYYY/MM/DD/` for today + yesterday and returns
/// the rollout `*.jsonl` files found there (D-01 / Pitfall 4).
///
/// **Date math is component-based, never string-based.** Yesterday is computed
/// via `Calendar.date(byAdding: .day, value: -1, ...)` so DST transitions and
/// leap-day boundaries are handled by Foundation — see Pitfall 4 / STATE #16.
///
/// **No formatter types** are used for directory-path
/// formatting (UI-04 / STATE #16). `String(format: "%04d/%02d/%02d", ...)` from
/// `DateComponents` is the deterministic path — Foundation's locale-aware
/// formatters default to UTC, which would split "today" at the wrong instant.
///
/// **Returned URLs are symlink-canonicalised** via `url.resolvingSymlinksInPath()`
/// so that downstream cache keys (offset cache in Plan 03-04, mirroring Phase 2
/// STATE #44) match regardless of whether the caller constructed paths via
/// `/var` or `/private/var`.
///
/// **Missing date directories do not throw** — they log at `.notice` level and
/// are skipped. A cold-launch user who has only used Codex today (or only
/// yesterday) still gets the partial result.
public struct CodexRolloutScanner: Sendable {

    // MARK: - Stored properties

    private let now: Date
    // nonisolated(unsafe): FileManager is not Sendable in Swift 6; .default is
    // the documented thread-safe singleton. Read-only enumeration only.
    nonisolated(unsafe) private let fileManager: FileManager
    private let calendar: Calendar
    private let root: URL?

    private let logger = AppLogger.logger(category: "codex.scan")

    // MARK: - Init

    /// - Parameters:
    ///   - now: Wall-clock instant treated as "today". Tests inject a pinned
    ///     date to exercise DST / leap-day / month boundaries deterministically.
    ///   - fileManager: Defaults to the shared singleton.
    ///   - calendar: Defaults to `Calendar.current` (Pitfall 4). Tests inject an
    ///     explicit PT or UTC calendar to assert host-tz-independent behaviour.
    ///   - root: Optional override of `CodexRoots.defaultRoot`. Production code
    ///     passes the default; tests pass a tempdir fixture root.
    public init(
        now: Date,
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        root: URL? = CodexRoots.defaultRoot
    ) {
        self.now = now
        self.fileManager = fileManager
        self.calendar = calendar
        self.root = root
    }

    // MARK: - Public API

    /// Returns the rollout `*.jsonl` files under `<root>/YYYY/MM/DD` for
    /// today's and yesterday's local-calendar dates (D-01).
    ///
    /// - Returns: Flat, unsorted array of symlink-canonical absolute URLs.
    ///   Consumer parsers fold across this list to find the latest valid
    ///   `event_msg.token_count` event (Plan 03-01 Task 3), so order is
    ///   intentionally not guaranteed.
    public func rolloutFiles() -> [URL] {
        guard let root else { return [] }
        guard fileManager.fileExists(atPath: root.path) else {
            // Root missing on disk — treat as "no Codex data".
            return []
        }

        // Component-based date math — see Pitfall 4 / STATE #16. Never use
        // a locale formatter or string subtraction; let Foundation handle DST + leap.
        let todayStart = calendar.startOfDay(for: now)
        // Force-unwrap is safe: `byAdding: .day, value: -1` on a valid start-of-day
        // always yields a valid Date (24-, 23-, or 25-hour days all handled).
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!

        var results: [URL] = []
        for date in [todayStart, yesterdayStart] {
            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            // Force-unwrap is safe: `dateComponents([.year,.month,.day],from:)`
            // always populates all three components for a non-nil Date.
            let dir = root
                .appendingPathComponent(String(format: "%04d", comps.year!), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.month!), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.day!), isDirectory: true)

            results.append(contentsOf: jsonlFiles(in: dir))
        }
        return results
    }

    // MARK: - Helpers

    private func jsonlFiles(in dir: URL) -> [URL] {
        guard fileManager.fileExists(atPath: dir.path) else {
            // Missing date dir is expected (yesterday may not exist for cold-launch
            // users); log at .notice and skip — never throw.
            logger.notice("date dir missing: \(dir.lastPathComponent, privacy: .public)")
            return []
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            logger.warning("contentsOfDirectory failed: \(dir.lastPathComponent, privacy: .public)")
            return []
        }

        return entries.compactMap { url in
            guard url.pathExtension == "jsonl" else { return nil }
            // Resolve symlinks so downstream cache keys are canonical (STATE #44).
            return url.resolvingSymlinksInPath()
        }
    }
}

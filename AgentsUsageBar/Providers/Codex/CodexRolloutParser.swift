import Foundation
import os

/// Fold across `[URL]` of Codex rollout JSONL files and return the latest valid
/// `event_msg.token_count` event with `payload.info != nil`.
///
/// **Why a fold across files (not a "latest file" pick):** A long-running session
/// pinned to yesterday's date dir keeps emitting events today; today's date dir
/// may also contain a brand-new session with fewer cumulative tokens. The
/// authoritative "session total" is the event with the largest `timestamp`
/// across the entire today+yesterday window (Pitfall 11 / RESEARCH.md
/// §"Scan strategy").
///
/// **Pitfall 5 (truncated lines):** Codex CLI may be mid-write when we scan.
/// Malformed JSON lines are silently skipped via `try?` decoding.
///
/// **CLAUDE-03 / Pitfall 7 (forward-compat):** Unknown future fields do NOT
/// throw — `JSONDecoder` ignores keys the struct does not declare.
///
/// **Whole-file synchronous read is intentional for Plan 03-01.** Codex rollout
/// files cap at a few MB per session lifetime. Plan 03-04 (`TranscriptReader`
/// integration with offset cache) is when streaming-by-delta lands; until then,
/// `String(contentsOf:encoding:)` matches Phase 2 STATE #43's justification for
/// `FileHandle.readToEnd()` over `URL.lines` (which throws CancellationError
/// under parallel test load).
public enum CodexRolloutParser {

    private static let logger = AppLogger.logger(category: "codex.parse")

    // Pitfall 3 — dual ISO8601 parsers. Codex rollout timestamps ship with
    // fractional seconds in the current format (`.000Z`); legacy files
    // occasionally omit them. Mirror Phase 2 `TranscriptRecord.parseISO8601`.
    //
    // `nonisolated(unsafe)` is safe: `ISO8601DateFormatter.date(from:)` is
    // documented thread-safe; we never mutate `formatOptions` after init.
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

    private static func parseISO8601(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoNoFractional.date(from: s)
    }

    /// Returns the latest valid `event_msg.token_count` event across all input
    /// files, paired with the file URL it came from.
    ///
    /// - Parameters:
    ///   - fileURLs: List of rollout JSONL URLs (from `CodexRolloutScanner`).
    ///     Order does not matter — the fold compares `event.timestamp` to find
    ///     the absolute maximum.
    ///   - decoder: Defaults to a fresh `JSONDecoder`. Injectable for tests.
    /// - Returns: `nil` if no file contained any valid `event_msg.token_count`
    ///   event with `payload.info != nil`.
    public static func lastTokenCount(
        in fileURLs: [URL],
        using decoder: JSONDecoder = JSONDecoder()
    ) -> (event: CodexRolloutEvent, fileURL: URL)? {

        var best: (event: CodexRolloutEvent, fileURL: URL, parsedTimestamp: Date)?
        // Rate-limit windows are account-level, not session-level. After a
        // usage-limit hit Codex writes a later `token_count` with
        // `primary`/`secondary` JSON null (`limit_id` flips to `"premium"`),
        // often in the same file and sometimes only in a newer session file.
        // Fold the latest windows independently of the latest token event so
        // file-scan order cannot drop quota to nil ("no limit" gray bar).
        var lastWindows: (limits: CodexRolloutEvent.RateLimits, timestamp: Date)?

        for url in fileURLs {
            // Whole-file synchronous read — Plan 03-04 integrates streaming
            // via `TranscriptReader` + offset cache. Codex rollout files are
            // KB-to-low-MB range.
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                logger.notice("read failed: \(url.lastPathComponent, privacy: .public)")
                continue
            }

            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8) else { continue }

                // Pitfall 5 — malformed/truncated lines decoded with `try?`
                // are silently skipped (returns nil). The fold continues.
                guard let event = try? decoder.decode(CodexRolloutEvent.self, from: data) else {
                    continue
                }

                // Predicate: only event_msg lines with payload.type == "token_count"
                // AND payload.info != nil qualify (RESEARCH correction #1 +
                // Pitfall 11). Everything else (session_meta, response_item,
                // turn_context, agent_message, …) is intentionally ignored.
                guard event.type == "event_msg",
                      event.payload.type == "token_count",
                      event.payload.info != nil
                else { continue }

                guard let parsedTs = parseISO8601(event.timestamp) else {
                    // Unparseable timestamp — keep the event out of the fold
                    // rather than fold it under a bogus ordering. Codex writes
                    // ISO8601, so this branch should be unreachable in practice.
                    continue
                }

                if let limits = event.payload.rateLimits, limits.hasWindows {
                    if lastWindows == nil || parsedTs >= lastWindows!.timestamp {
                        lastWindows = (limits, parsedTs)
                    }
                }

                if best == nil || parsedTs > best!.parsedTimestamp {
                    best = (event, url, parsedTs)
                }
            }
        }

        guard let best else { return nil }

        if best.event.payload.rateLimits?.hasWindows != true,
           let lastWindows,
           lastWindows.timestamp <= best.parsedTimestamp {
            if let current = best.event.payload.rateLimits {
                return (
                    best.event.withRateLimits(current.fillingEmptyWindows(from: lastWindows.limits)),
                    best.fileURL
                )
            }
            return (best.event.withRateLimits(lastWindows.limits), best.fileURL)
        }

        return (best.event, best.fileURL)
    }
}

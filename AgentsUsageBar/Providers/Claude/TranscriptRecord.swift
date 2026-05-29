import Foundation

/// One assistant-message record decoded from a single JSONL line in
/// `~/.claude/projects/**/*.jsonl`.
///
/// CLAUDE-03: tolerates unknown top-level + nested fields (forward-compat with
/// future Claude transcript schema additions — see RESEARCH Pattern 2).
///
/// Pitfall 8: the fast-path `line.contains("\"type\":\"assistant\"")` gates 99% of
/// non-assistant lines without a JSON parse, keeping the poll loop cheap.
///
/// Pitfall 3: ISO8601 timestamps are tolerated WITH or WITHOUT fractional seconds
/// (the canonical Claude transcript ships `.NNN`, but some older sessions and
/// system-emitted lines omit them).
///
// MARK: - DO NOT switch to URL.lines — see CLAUDE-02 / RESEARCH Pitfall 1
// `URL.lines` has no offset-resume primitive and would force whole-file re-reads
// on every poll. We use `FileHandle.seek` + `.bytes.lines` in `TranscriptReader`.
//
// Decoder choice: `JSONSerialization` + `as? T ?? defaultValue` per RESEARCH
// Pattern 2. A strict `Codable` struct would reject the line on any unknown
// field; we want forward-compat leniency, so we walk the dictionary manually.
public struct TranscriptRecord: Sendable, Equatable {
    public let timestamp: Date
    public let model: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let requestID: String?

    public init(
        timestamp: Date,
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        requestID: String?
    ) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.requestID = requestID
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    // Pitfall 3 — dual ISO8601 parsers. ISO8601DateFormatter cannot accept both
    // shapes with a single instance; we keep both and try the strict-fractional
    // one first since that is the common Claude transcript format.
    //
    // `nonisolated(unsafe)` is safe here because ISO8601DateFormatter's `date(from:)`
    // is thread-safe per Apple documentation, and we never mutate formatOptions
    // after the initial `{}()` closure runs at first access.
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

    /// Decodes a single JSONL line. Returns `nil` for non-assistant lines, lines
    /// without a `message.usage` block, or malformed JSON (consume-and-skip — see
    /// Pitfall 8). Callers must still advance the file offset past the consumed
    /// bytes regardless of return value.
    public static func decode(from line: String) -> TranscriptRecord? {
        // Pitfall 8 fast-path: substring scan short-circuits 99% of lines before
        // we ever invoke JSONSerialization. Critical for keeping CPU low across
        // tens of thousands of non-assistant lines per session.
        guard line.contains("\"type\":\"assistant\"") else { return nil }

        guard
            let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        // Double-check after parse: the fast-path can match assistant references
        // inside unrelated string content. Authoritative gate is the parsed value.
        guard (json["type"] as? String) == "assistant" else { return nil }

        guard
            let timestampString = json["timestamp"] as? String,
            let timestamp = parseISO8601(timestampString)
        else {
            return nil
        }

        guard
            let message = json["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any]
        else {
            return nil
        }

        let inputTokens = (usage["input_tokens"] as? Int) ?? 0
        let outputTokens = (usage["output_tokens"] as? Int) ?? 0
        let cacheCreationTokens = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        let cacheReadTokens = (usage["cache_read_input_tokens"] as? Int) ?? 0

        let model = message["model"] as? String
        // ccusage uses top-level `requestId` for cross-file dedup (RESEARCH §A.9 /
        // Open Question 5). Optional — older transcripts may omit it.
        let requestID = json["requestId"] as? String

        return TranscriptRecord(
            timestamp: timestamp,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            requestID: requestID
        )
    }
}

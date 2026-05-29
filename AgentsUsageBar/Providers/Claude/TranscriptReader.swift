import Foundation
import os

// MARK: - DO NOT switch to URL.lines — see CLAUDE-02 / Pitfall 1
// `URL.lines` has no offset-resume primitive and would force whole-file re-reads
// on every poll. We use `FileHandle.seek(toOffset:)` + `.bytes.lines` here.
//
// Pitfall 2: each `.bytes.lines` iteration ends at a `\n` — every iteration
// boundary is a clean record boundary. `newOffset` is the position AFTER the
// last fully-iterated `\n`, NOT EOF. This crash-safety invariant must be preserved.

/// Actor that streams Claude JSONL transcript files with byte-offset resume.
///
/// CLAUDE-02: Only bytes past `startOffset` are read on each poll. The returned
/// `newOffset` is used to construct the next-poll `TranscriptOffset` persisted
/// in `FileCacheStore` (schemaVersion 2).
///
/// RESEARCH §A.2 truncation defense: when the file's current mtime is earlier
/// than `previousLastModified`, the file has been truncated or replaced and we
/// restart from offset 0 rather than seeking past valid data.
///
/// Codex Phase 3 reuse: this actor is intentionally provider-agnostic — it reads
/// any JSONL file using `TranscriptRecord.decode(from:)`.
public actor TranscriptReader {

    // MARK: - Nested types

    /// The result of a single delta-read pass over a JSONL file.
    public struct ReadResult: Sendable {
        /// Records decoded from lines at or beyond `startOffset`. Only `type:"assistant"` lines.
        public let records: [TranscriptRecord]
        /// Position AFTER the last fully-iterated `\n`. Safe to pass as `startOffset` next poll.
        public let newOffset: UInt64
        /// File mtime at the time of this read. Persist in `TranscriptOffset.lastModified`.
        public let lastModified: Date
    }

    // MARK: - Properties

    private let logger = AppLogger.logger(category: "jsonl")

    // MARK: - Initializers

    public init() {}

    // MARK: - Public API

    /// Reads new records from `fileURL` starting at `startOffset`.
    ///
    /// - Parameters:
    ///   - fileURL: Absolute URL of the `.jsonl` file to stream.
    ///   - startOffset: Byte offset to seek to before reading. Pass `0` for first read.
    ///   - previousLastModified: The `lastModified` value from the prior `ReadResult`.
    ///     When non-nil and the current file mtime is earlier than this value,
    ///     the file is treated as truncated/replaced and reading restarts from offset 0.
    /// - Returns: `ReadResult` with decoded records and safe next-poll offset.
    /// - Throws: `CocoaError(.fileNoSuchFile)` (propagated from `FileHandle`) if file is missing.
    public func readDelta(
        from fileURL: URL,
        startOffset: UInt64,
        previousLastModified: Date?
    ) async throws -> ReadResult {
        let fm = FileManager.default

        // Resolve current mtime before opening the file.
        let attrs = try fm.attributesOfItem(atPath: fileURL.path)
        let currentMTime = (attrs[.modificationDate] as? Date) ?? .distantPast

        // RESEARCH §A.2 truncation defense: mtime regressed → file replaced.
        var seekTo = startOffset
        if let prev = previousLastModified, currentMTime < prev {
            logger.warning(
                "transcript truncation detected at \(fileURL.lastPathComponent, privacy: .public); restarting from offset 0"
            )
            seekTo = 0
        }

        let fh = try FileHandle(forReadingFrom: fileURL)
        defer { try? fh.close() }

        try fh.seek(toOffset: seekTo)

        var records: [TranscriptRecord] = []
        var bytesConsumed: UInt64 = 0

        for try await line in fh.bytes.lines {
            // Pitfall 2: each .bytes.lines iteration ends at a \n — boundary is always clean.
            // +1 accounts for the LF that `.lines` strips from each yielded string.
            bytesConsumed += UInt64(line.utf8.count) + 1

            if let record = TranscriptRecord.decode(from: line) {
                records.append(record)
            }
            // Malformed lines still consume bytes — Pitfall 8: consume-and-skip.
        }

        return ReadResult(
            records: records,
            newOffset: seekTo + bytesConsumed,
            lastModified: currentMTime
        )
    }
}

import Foundation
import os

// MARK: - DO NOT switch to URL.lines — see CLAUDE-02 / Pitfall 1
// `URL.lines` has no offset-resume primitive and would force whole-file re-reads
// on every poll. We use `FileHandle.seek(toOffset:)` + synchronous `readDataToEndOfFile`
// followed by manual `\n` splitting.
//
// WHY NOT fh.bytes.lines (async AsyncSequence):
// `FileHandle.AsyncBytes.lines` is cancellation-sensitive — a `CancellationError` is
// thrown when the enclosing Swift concurrency task is cancelled. Under a large parallel
// test suite (or high-load production polling), external task cancellation propagates
// into the async iteration and surfaces as a spurious fetch failure. Synchronous
// `readDataToEndOfFile` is not cancellation-sensitive and is safe for our use case
// because JSONL transcript files are small (KB-range per poll delta).
//
// Pitfall 2 invariant preserved: we split on `\n` byte (0x0A) manually. Each split
// boundary is a clean JSONL record boundary. `newOffset` is seekTo + bytes consumed
// up to and including the last `\n`, NOT EOF. A trailing incomplete line (no final `\n`)
// is NOT counted in bytesConsumed — newOffset stays before it so the next poll re-reads it.

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
    ///   Does NOT throw `CancellationError` — synchronous I/O is not cancellation-sensitive.
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

        // Synchronous read of all bytes from seekTo to EOF.
        // Safe for our use case: JSONL delta chunks are KB-range, not GB-range.
        // This avoids cancellation sensitivity of `fh.bytes.lines` (AsyncSequence).
        // Use `readToEnd()` (Swift-native, throws) rather than `readDataToEndOfFile()`
        // (ObjC-bridged, throws NSException silently swallowed by Swift runtime).
        let data = try fh.readToEnd() ?? Data()
        logger.debug("readDelta: file=\(fileURL.lastPathComponent, privacy: .public) seekTo=\(seekTo) dataBytes=\(data.count)")

        var records: [TranscriptRecord] = []
        var bytesConsumed: UInt64 = 0

        // Split on LF (0x0A). Each chunk is one JSONL line without its trailing newline.
        // Pitfall 2 invariant: we consume bytes up to and including each `\n`.
        // A trailing incomplete line (no final `\n`) is NOT counted in bytesConsumed —
        // newOffset stays at the start of that incomplete line so the next poll re-reads it.
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            if let lfIndex = data[lineStart...].firstIndex(of: 0x0A) {
                // Full line terminated by \n.
                let lineData = data[lineStart..<lfIndex]
                let lineByteCount = UInt64(lineData.count) + 1  // +1 for the LF
                bytesConsumed += lineByteCount
                if let line = String(data: lineData, encoding: .utf8) {
                    if let record = TranscriptRecord.decode(from: line) {
                        records.append(record)
                    }
                    // Malformed lines still consume bytes — Pitfall 8: consume-and-skip.
                }
                lineStart = data.index(after: lfIndex)
            } else {
                // Trailing incomplete line (no final \n) — consume bytes, yield no record.
                // This is safe: the next poll will re-read these bytes from the same offset.
                // We do NOT advance bytesConsumed past an incomplete line, so newOffset
                // points to the start of this incomplete line — correct resume semantics.
                break
            }
        }

        return ReadResult(
            records: records,
            newOffset: seekTo + bytesConsumed,
            lastModified: currentMTime
        )
    }
}

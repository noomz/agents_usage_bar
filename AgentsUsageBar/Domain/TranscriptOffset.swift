import Foundation

/// Per-file resume cursor for Claude JSONL streaming (CLAUDE-02).
///
/// `byteOffset` is the position AFTER the last fully-parsed `\n` so a crash mid-write
/// never causes us to re-read partial bytes. Persisted in `FileCacheStore` envelope v2.
///
/// RESEARCH §A.2 truncation defense: when a file's current mtime is earlier than the
/// `lastModified` stored here, the reader treats the file as truncated/replaced and
/// restarts from offset 0.
public struct TranscriptOffset: Sendable, Codable, Equatable {
    public let url: String
    public let byteOffset: UInt64
    public let lastModified: Date

    public init(url: String, byteOffset: UInt64, lastModified: Date) {
        self.url = url
        self.byteOffset = byteOffset
        self.lastModified = lastModified
    }
}

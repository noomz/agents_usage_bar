import Foundation
import os

/// Byte-offset JSONL reader. Sendable struct so file fan-out is real.
struct PiSessionReader: Sendable {
    struct ReadResult: Sendable {
        let records: [PiSessionRecord]
        let newOffset: UInt64
        let lastModified: Date
    }

    private let logger = AppLogger.logger(category: "pi-local")

    init() {}

    func readDelta(
        from fileURL: URL,
        startOffset: UInt64,
        previousLastModified: Date?
    ) throws -> ReadResult {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: fileURL.path)
        let currentMTime = (attrs[.modificationDate] as? Date) ?? .distantPast

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
        let data = try fh.readToEnd() ?? Data()

        var records: [PiSessionRecord] = []
        var bytesConsumed: UInt64 = 0
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            if let lfIndex = data[lineStart...].firstIndex(of: 0x0A) {
                let lineData = data[lineStart..<lfIndex]
                bytesConsumed += UInt64(lineData.count) + 1
                if let line = String(data: lineData, encoding: .utf8),
                   let record = PiSessionRecord.decode(from: line) {
                    records.append(record)
                }
                lineStart = data.index(after: lfIndex)
            } else {
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

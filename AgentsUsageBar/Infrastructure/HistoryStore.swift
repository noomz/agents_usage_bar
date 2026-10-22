import Foundation
import os.log

/// The app's writer for `history/` (SPEC I9, V14), separate from `FileCacheStore`.
///
/// After each poll, `record(_:at:)` folds the good samples into the open day and writes the
/// day file atomically only when a merged value changed (V15). The open day is seeded from
/// its file on the first poll, so building the store does no I/O (V61). The first poll on a
/// later day key does a final merge into the previous file, and polling never writes that
/// sealed file again (V16). The first poll and every seal also prune past 90 days (V17).
public actor HistoryStore {
    /// Day keys kept before the current key (V17).
    public static let retainedDays = 90

    private let reader: HistoryReader
    private let dayKeys: DayKeyOwner
    private let logger = AppLogger.logger(category: "history")

    /// The key polls write to, nil before the first poll.
    private var openKey: String?
    /// The open day as merged in memory. Nil when its file is skipped, so it is never
    /// overwritten (V18).
    private var open: DayFile?
    /// The open day as last read or written; nil when it has no file.
    private var onDisk: DayFile?

    public init(directory: URL = HistoryReader.defaultDirectory, dayKeys: DayKeyOwner) {
        self.reader = HistoryReader(directory: directory)
        self.dayKeys = dayKeys
    }

    /// Folds one poll's good samples (providers `.ok` on this poll) into the open day.
    public func record(_ samples: [UsageSnapshot], at now: Date) async {
        // A sealed day never reopens (V16). T6 adds the rest of the monotonic key (V4, V5).
        let key = max(dayKeys.key(for: now), openKey ?? "")
        if key != openKey {
            await seal(opening: key)
        }
        guard let day = open else { return }
        let merged = day.merging(samples, at: now, timeZone: dayKeys.timeZoneIdentifier)
        open = merged
        if let onDisk, merged.hasSameContent(as: onDisk) { return }
        if onDisk == nil, merged.records.isEmpty { return }
        write(merged)
    }

    /// Final merge into the previous open day, prune, then seed `key` from its file.
    private func seal(opening key: String) async {
        if let open, open != onDisk, !open.records.isEmpty {
            write(open)
        }
        await prune(relativeTo: key)
        openKey = key
        let url = reader.fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            open = DayFile(date: key, timeZone: dayKeys.timeZoneIdentifier)
            onDisk = nil
            return
        }
        // Nil means the reader skipped and logged the file (V18).
        open = await reader.day(key)
        onDisk = open
    }

    /// Deletes day files more than `retainedDays` before `key`. Files this build cannot
    /// read are left alone (V18).
    private func prune(relativeTo key: String) async {
        guard let cutoff = dayKeys.key(key, addingDays: -Self.retainedDays),
              let keys = try? await reader.dayKeys()
        else { return }
        for old in keys where old < cutoff {
            guard await reader.day(old) != nil else { continue }
            do {
                try FileManager.default.removeItem(at: reader.fileURL(for: old))
            } catch {
                logger.error("history prune \(old, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Temp file plus rename, so a reader sees the old file or the new one (V15, V19).
    private func write(_ day: DayFile) {
        do {
            try FileManager.default.createDirectory(at: reader.directory, withIntermediateDirectories: true)
            try day.encoded().write(to: reader.fileURL(for: day.date), options: .atomic)
            onDisk = day
        } catch {
            logger.error("history write \(day.date, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

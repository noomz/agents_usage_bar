import Foundation
import os.log

/// Read-only view of `history/` (SPEC I9), for `aub` and the app's user-action reads.
///
/// It never creates the directory, writes, prunes, migrates on disk, or reads
/// `.account-salt`; a missing directory is empty history (V19). Reads are `nonisolated async`,
/// so decoding runs off the MainActor (V20). There is no locking: the writer renames whole
/// files into place, so a read sees an old file or a new one, never a partial one.
public struct HistoryReader: Sendable {
    /// `~/Library/Application Support/AgentsUsageBar/history/`, resolved without creating it.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AgentsUsageBar/history", directoryHint: .isDirectory)
    }

    public let directory: URL
    private let logger = AppLogger.logger(category: "history")

    public init(directory: URL = HistoryReader.defaultDirectory) {
        self.directory = directory
    }

    /// The URL of the day file for `key`.
    public func fileURL(for key: String) -> URL {
        directory.appending(path: "\(key).json", directoryHint: .notDirectory)
    }

    /// Day keys with a file on disk, oldest first. Throws when `history/` exists but cannot
    /// be listed.
    public nonisolated func dayKeys() async throws -> [String] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        return names.compactMap { name in
            guard name.wholeMatch(of: /\d{4}-\d{2}-\d{2}\.json/) != nil else { return nil }
            return String(name.dropLast(".json".count))
        }.sorted()
    }

    /// Every readable day file whose key is in `keys`, oldest first. Files that are newer,
    /// unknown, or unreadable are skipped and logged, and left untouched (V18).
    public nonisolated func days(in keys: ClosedRange<String>? = nil) async throws -> [DayFile] {
        var days: [DayFile] = []
        for key in try await dayKeys() where keys?.contains(key) ?? true {
            if let day = await day(key) { days.append(day) }
        }
        return days
    }

    /// The day file for `key`, or nil when it is missing or skipped (V18).
    public nonisolated func day(_ key: String) async -> DayFile? {
        guard let data = try? Data(contentsOf: fileURL(for: key)) else { return nil }
        switch DayFile.decode(data) {
        case .file(let day) where day.date == key:
            return day
        case .file(let day):
            logger.warning("history \(key, privacy: .public).json skipped: holds date \(day.date, privacy: .public)")
        case .unsupported(let version):
            logger.warning("history \(key, privacy: .public).json skipped: schemaVersion \(version, privacy: .public)")
        case .unreadable:
            logger.warning("history \(key, privacy: .public).json skipped: unreadable")
        }
        return nil
    }
}

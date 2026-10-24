import CryptoKit
import Foundation
import os.log

/// The app's writer for `history/` (SPEC I9, V14), separate from `FileCacheStore`.
///
/// After each poll, `record(_:at:)` folds the good samples into the open day and writes the
/// day file atomically only when a merged value changed (V15). The open day is seeded from
/// its file on the first poll, so building the store does no I/O (V61). The first poll on a
/// later day key does a final merge into the previous file, and polling never writes that
/// sealed file again (V16). The first poll and every seal also prune past 90 days (V17).
///
/// The store keeps the shared `DayKeyOwner` at the newest day key (V4): it seeds it from the
/// newest day file and advances it as it opens days, so a wall clock set back keeps writing
/// the newest day, and one more than 1 day back pauses writes (V5).
///
/// Every seal starts gap-fill (V27): one low-priority pass over the backfill sources, whose
/// writes come back through `backfill(_:on:)` so the store stays the only writer (V32).
public actor HistoryStore {
    /// Day keys kept before the current key (V17).
    public static let retainedDays = 90
    /// The per-install salt for account keys (V21, ADR 0003).
    public static let saltFileName = ".account-salt"

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
    /// True once the owner was seeded from disk, so a paused poll does no I/O.
    private var seeded = false
    /// True while writes pause for a clock error, so it is logged once (V5).
    private var paused = false
    /// Loaded from `.account-salt` the first time an account id needs a key.
    private var salt: Data?
    private let gapFill: HistoryBackfill
    /// The running gap-fill pass, nil when idle.
    private var gapFillTask: Task<Void, Never>?
    /// A seal during a pass asks for one more, so a newly sealed day is not missed.
    private var gapFillAgain = false

    public init(
        directory: URL = HistoryReader.defaultDirectory,
        dayKeys: DayKeyOwner,
        backfillSources: [any BackfillSource] = []
    ) {
        self.reader = HistoryReader(directory: directory)
        self.dayKeys = dayKeys
        self.gapFill = HistoryBackfill(sources: backfillSources, reader: reader, dayKeys: dayKeys)
    }

    /// The day key polls write to, nil before the first poll.
    public var openDayKey: String? {
        openKey
    }

    /// Raises the day-key owner to the newest day file's key (V4). Reads the directory
    /// listing only.
    public func seedNewestKey() async {
        seeded = true
        if let newest = try? await reader.dayKeys().last {
            dayKeys.advanceNewest(to: newest)
        }
    }

    /// Folds one poll's good samples (providers `.ok` on this poll) into the open day, and
    /// appends the poll's usage events on the same write (V38).
    public func record(_ samples: [UsageSnapshot], events: [UsageEvent] = [], at now: Date) async {
        if !seeded {
            await seedNewestKey()
        }
        guard !dayKeys.isClockBehind(at: now) else {
            if !paused {
                logger.error("history writes paused: wall clock \(self.dayKeys.wallKey(for: now), privacy: .public) is more than 1 day behind \(self.dayKeys.key(for: now), privacy: .public)")
            }
            paused = true
            return
        }
        paused = false
        // Never below the open key, so a sealed day never reopens (V4, V16).
        let key = dayKeys.key(for: now)
        if key != openKey {
            await seal(opening: key)
        }
        guard let day = open else { return }
        var merged = day.merging(samples, at: now, timeZone: dayKeys.timeZoneIdentifier) { accountID in
            DayAccount.key(forAccountID: accountID, salt: accountSalt())
        }
        merged.events += events
        open = merged
        if let onDisk, merged.hasSameContent(as: onDisk) { return }
        if onDisk == nil, merged.isEmpty { return }
        if write(merged) {
            onDisk = merged
        }
    }

    /// Folds one provider's backfilled record into the sealed day `key` and marks the
    /// provider checked (V29–V31). The open day, days past retention, a provider already
    /// checked, and files this build cannot read are left alone (V17, V18, V27).
    public func backfill(_ record: DayRecord, on key: String) async {
        guard !paused, let openKey, key < openKey,
              let cutoff = dayKeys.key(openKey, addingDays: -Self.retainedDays), key >= cutoff
        else { return }
        let day: DayFile
        if FileManager.default.fileExists(atPath: reader.fileURL(for: key).path(percentEncoded: false)) {
            guard let read = await reader.day(key) else { return }
            day = read
        } else {
            day = DayFile(date: key, timeZone: dayKeys.timeZoneIdentifier)
        }
        guard !day.backfillChecked.contains(record.provider) else { return }
        write(day.backfilling(record))
    }

    /// A backfill source's accounts as day accounts, keyed with this install's salt (V21, V62).
    func backfillAccounts(_ accounts: [UsageSnapshot.AccountUsage], of provider: ProviderID) -> [DayAccount] {
        guard !accounts.isEmpty else { return [] }
        let sample = UsageSnapshot(
            providerID: provider, asOf: .distantPast, tokensToday: nil, costTodayUSD: nil,
            balanceUSD: nil, quota: nil, raw: [:], accounts: accounts)
        return sample.dayAccounts { accountID in
            DayAccount.key(forAccountID: accountID, salt: accountSalt())
        }
    }

    /// Waits for a running gap-fill pass, including any pass a seal queued behind it.
    func gapFillFinished() async {
        while let task = gapFillTask {
            await task.value
        }
    }

    /// Starts a gap-fill pass, or queues one more when a pass is running (V27).
    private func startGapFill() {
        guard gapFillTask == nil else {
            gapFillAgain = true
            return
        }
        gapFillTask = Task(priority: .background) {
            repeat {
                self.gapFillAgain = false
                await self.gapFill.run(into: self)
            } while self.gapFillAgain
            self.gapFillTask = nil
        }
    }

    /// Final merge into the previous open day, prune, then seed `key` from its file.
    private func seal(opening key: String) async {
        if let open, open != onDisk, !open.isEmpty {
            write(open)
        }
        await prune(relativeTo: key)
        dayKeys.advanceNewest(to: key)
        openKey = key
        defer { startGapFill() }
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

    /// The salt from `.account-salt`, made on first need. A missing salt is made again, so
    /// Codex series split rather than a second copy being kept elsewhere (V21, ADR 0003).
    private func accountSalt() -> Data {
        if let salt { return salt }
        let url = reader.directory.appending(path: Self.saltFileName, directoryHint: .notDirectory)
        if let stored = try? Data(contentsOf: url), !stored.isEmpty {
            salt = stored
            return stored
        }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        do {
            try writePrivately(fresh, to: url)
        } catch {
            logger.error("history salt write failed: \(error.localizedDescription, privacy: .public)")
        }
        salt = fresh
        return fresh
    }

    @discardableResult
    private func write(_ day: DayFile) -> Bool {
        do {
            try writePrivately(day.encoded(), to: reader.fileURL(for: day.date))
            return true
        } catch {
            logger.error("history write \(day.date, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Temp file plus rename, so a reader sees the old file or the new one (V15, V19).
    /// `history/` is 0700 and its files 0600 (V23); the directory mode is set on every
    /// write so a directory made by an older build is tightened too.
    private func writePrivately(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = reader.directory.path(percentEncoded: false)
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }
}

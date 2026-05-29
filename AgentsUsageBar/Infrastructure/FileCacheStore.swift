import Foundation
import os.log

/// Production `CacheStore` backed by an atomic JSON file in Application Support.
///
/// File path (D-02): `~/Library/Application Support/AgentsUsageBar/today.json`
///
/// D-08: Writes are atomic — Foundation writes to a temp file then renames, so a
/// crash mid-write never leaves a partial file visible.
///
/// D-09: The file carries `schemaVersion: 1`. On schema mismatch or malformed JSON,
/// `loadAll()` returns `[:]` (cold-launch semantics) — never crashes, never shows stale
/// data from an incompatible format.
///
/// Thread safety: A concurrent `DispatchQueue` with `.barrier` for writes and plain
/// `.sync` for reads serialises all file access. `@unchecked Sendable` is safe because
/// the `url` is immutable after `init` and all mutable access goes through the queue.
public final class FileCacheStore: CacheStore, @unchecked Sendable {

    // MARK: - Nested types

    /// The on-disk representation. `schemaVersion` guards against format evolution.
    private struct CacheEnvelope: Codable, Sendable {
        let schemaVersion: Int
        let providers: [ProviderID: ProviderState]
        let baselines: [ProviderID: BaselineRecord]

        init(
            schemaVersion: Int = 1,
            providers: [ProviderID: ProviderState],
            baselines: [ProviderID: BaselineRecord]
        ) {
            self.schemaVersion = schemaVersion
            self.providers = providers
            self.baselines = baselines
        }
    }

    // MARK: - Properties

    private let url: URL
    private let logger = AppLogger.logger(category: "cache")
    private let queue = DispatchQueue(
        label: "app.agents-usage-bar.cache",
        attributes: .concurrent
    )

    // MARK: - Initializers

    /// Production initializer — creates `~/Library/Application Support/AgentsUsageBar/` if needed.
    public init() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("AgentsUsageBar", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("today.json", isDirectory: false)
    }

    /// Test seam — writes cache to an arbitrary root URL (e.g. a temp directory).
    internal init(testingRootURL: URL) throws {
        try FileManager.default.createDirectory(
            at: testingRootURL, withIntermediateDirectories: true)
        self.url = testingRootURL.appendingPathComponent("today.json", isDirectory: false)
    }

    // MARK: - Test support

    /// Exposes the cache file URL so tests can inject arbitrary JSON for negative-path cases.
    internal var cacheURLForTesting: URL { url }

    // MARK: - CacheStore

    public func loadAll() -> [ProviderID: ProviderState] {
        queue.sync { _loadEnvelope()?.providers ?? [:] }
    }

    public func save(_ providers: [ProviderID: ProviderState]) {
        queue.sync(flags: .barrier) {
            let existing = _loadEnvelope()
            let envelope = CacheEnvelope(
                schemaVersion: 1,
                providers: providers,
                baselines: existing?.baselines ?? [:]
            )
            _writeEnvelope(envelope)
        }
    }

    public func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? {
        queue.sync { _loadEnvelope()?.baselines[id] }
    }

    public func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {
        queue.sync(flags: .barrier) {
            let envelope = _loadEnvelope() ?? CacheEnvelope(providers: [:], baselines: [:])
            let today = TodayHelper.formatYYYYMMDD(now)
            let existing = envelope.baselines[id]

            let newRecord: BaselineRecord
            if existing == nil || existing!.date != today {
                // Cold start or new calendar day — set fresh baseline (D-05)
                newRecord = BaselineRecord(
                    value: currentValue,
                    date: today,
                    lastValue: currentValue,
                    lastUpdated: now
                )
            } else if currentValue < existing!.value {
                // Negative delta (refund / manual reset) — D-04
                logger.warning(
                    "Baseline reset for \(id.rawValue, privacy: .public): \(existing!.value, privacy: .public) → \(currentValue, privacy: .public)"
                )
                newRecord = BaselineRecord(
                    value: currentValue,
                    date: today,
                    lastValue: currentValue,
                    lastUpdated: now
                )
            } else {
                // Normal positive delta — keep baseline, update lastValue
                newRecord = BaselineRecord(
                    value: existing!.value,
                    date: today,
                    lastValue: currentValue,
                    lastUpdated: now
                )
            }

            var updatedBaselines = envelope.baselines
            updatedBaselines[id] = newRecord
            let updated = CacheEnvelope(
                schemaVersion: 1,
                providers: envelope.providers,
                baselines: updatedBaselines
            )
            _writeEnvelope(updated)
        }
    }

    // MARK: - Private helpers (call only from within `queue`)

    private func _loadEnvelope() -> CacheEnvelope? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let env = try JSONDecoder().decode(CacheEnvelope.self, from: data)
            guard env.schemaVersion == 1 else {
                logger.notice("cache schemaVersion mismatch (\(env.schemaVersion, privacy: .public)); ignoring")
                return nil
            }
            return env
        } catch {
            logger.warning("cache decode failed; cold-start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func _writeEnvelope(_ envelope: CacheEnvelope) {
        do {
            let data = try JSONEncoder().encode(envelope)
            // .atomic = Foundation writes to a temp file then renames. Crash-safe (D-08).
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

import Foundation
import os.log

/// Production `CacheStore` backed by an atomic JSON file in Application Support.
///
/// File path (D-02): `~/Library/Application Support/AgentsUsageBar/today.json`
///
/// D-08: Writes are atomic — Foundation writes to a temp file then renames, so a
/// crash mid-write never leaves a partial file visible.
///
/// D-09: The file carries `schemaVersion: 2` (Plan 02.01). On schema mismatch or
/// malformed JSON, `loadAll()` returns `[:]` (cold-launch semantics) — never crashes,
/// never shows stale data from an incompatible format.
///
/// schemaVersion history:
/// - 1: providers + baselines (Phase 1)
/// - 2: + transcripts: [String: TranscriptOffset] (Plan 02.01)
///   v1 → v2 migration: a v1 file on disk is automatically upgraded on first load;
///   existing `providers` and `baselines` are preserved (HIGH-risk migration mitigated
///   — see RESEARCH schemaVersion bump risk: HIGH).
/// - 3: + dailyUsage: [ProviderID: DailyUsageRecord] — per-provider day accumulator
///   for delta-sourced JSONL providers. v1/v2 → v3 migration seeds an empty map;
///   the accumulator self-heals on the next poll, so no historical data is lost
///   beyond the current partial day (acceptable — today-only aggregation).
///
/// Thread safety: A concurrent `DispatchQueue` with `.barrier` for writes and plain
/// `.sync` for reads serialises all file access. `@unchecked Sendable` is safe because
/// the `url` is immutable after `init` and all mutable access goes through the queue.
public final class FileCacheStore: CacheStore, @unchecked Sendable {

    // MARK: - Nested types

    /// The on-disk representation for schemaVersion 2.
    /// `schemaVersion` guards against format evolution.
    private struct CacheEnvelope: Codable, Sendable {
        let schemaVersion: Int
        let providers: [ProviderID: ProviderState]
        let baselines: [ProviderID: BaselineRecord]
        let transcripts: [String: TranscriptOffset]
        let dailyUsage: [ProviderID: DailyUsageRecord]

        init(
            schemaVersion: Int = 3,
            providers: [ProviderID: ProviderState],
            baselines: [ProviderID: BaselineRecord],
            transcripts: [String: TranscriptOffset] = [:],
            dailyUsage: [ProviderID: DailyUsageRecord] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.providers = providers
            self.baselines = baselines
            self.transcripts = transcripts
            self.dailyUsage = dailyUsage
        }
    }

    /// Codable mirror of the schemaVersion 1 envelope — used solely in the v1→v3 migration path.
    /// Fields match exactly what Phase 1 wrote to disk.
    private struct CacheEnvelopeV1: Codable, Sendable {
        let schemaVersion: Int
        let providers: [ProviderID: ProviderState]
        let baselines: [ProviderID: BaselineRecord]
    }

    /// Codable mirror of the schemaVersion 2 envelope — used solely in the v2→v3 migration path.
    /// Fields match exactly what Plan 02.01 wrote to disk (no `dailyUsage`).
    private struct CacheEnvelopeV2: Codable, Sendable {
        let schemaVersion: Int
        let providers: [ProviderID: ProviderState]
        let baselines: [ProviderID: BaselineRecord]
        let transcripts: [String: TranscriptOffset]
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
                schemaVersion: 3,
                providers: providers,
                baselines: existing?.baselines ?? [:],
                transcripts: existing?.transcripts ?? [:],
                dailyUsage: existing?.dailyUsage ?? [:]
            )
            _writeEnvelope(envelope)
        }
    }

    public func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? {
        queue.sync { _loadEnvelope()?.baselines[id] }
    }

    public func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {
        queue.sync(flags: .barrier) {
            let envelope = _loadEnvelope() ?? CacheEnvelope(providers: [:], baselines: [:], transcripts: [:])
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
                schemaVersion: 3,
                providers: envelope.providers,
                baselines: updatedBaselines,
                transcripts: envelope.transcripts,
                dailyUsage: envelope.dailyUsage
            )
            _writeEnvelope(updated)
        }
    }

    // MARK: - CacheStore transcript offset methods (Plan 02.01 — CLAUDE-02)

    public func transcriptOffset(forURL urlString: String) -> TranscriptOffset? {
        queue.sync { _loadEnvelope()?.transcripts[urlString] }
    }

    public func setTranscriptOffset(_ offset: TranscriptOffset) {
        queue.sync(flags: .barrier) {
            let envelope = _loadEnvelope() ?? CacheEnvelope(providers: [:], baselines: [:], transcripts: [:])
            var ts = envelope.transcripts
            ts[offset.url] = offset
            let updated = CacheEnvelope(
                schemaVersion: 3,
                providers: envelope.providers,
                baselines: envelope.baselines,
                transcripts: ts,
                dailyUsage: envelope.dailyUsage
            )
            _writeEnvelope(updated)
        }
    }

    /// Atomic batch upsert — one envelope load, merge all offsets, one envelope
    /// write. Avoids the O(N²) decode/encode storm `setTranscriptOffset` would
    /// cause when called per-file after a multi-hundred-file fan-out
    /// (`ClaudeJSONLProvider.fetch` on a freshly-seeded cache).
    public func setTranscriptOffsets(_ offsets: [TranscriptOffset]) {
        guard !offsets.isEmpty else { return }
        queue.sync(flags: .barrier) {
            let envelope = _loadEnvelope() ?? CacheEnvelope(providers: [:], baselines: [:], transcripts: [:])
            var ts = envelope.transcripts
            for offset in offsets {
                ts[offset.url] = offset
            }
            let updated = CacheEnvelope(
                schemaVersion: 3,
                providers: envelope.providers,
                baselines: envelope.baselines,
                transcripts: ts,
                dailyUsage: envelope.dailyUsage
            )
            _writeEnvelope(updated)
        }
    }

    public func allTranscriptOffsets() -> [String: TranscriptOffset] {
        queue.sync { _loadEnvelope()?.transcripts ?? [:] }
    }

    // MARK: - Daily usage accumulator (delta → cumulative)

    public func accumulateDailyUsage(
        for id: ProviderID,
        now: Date,
        deltaTokens: Int,
        deltaCostUSD: Decimal
    ) -> (tokens: Int, costUSD: Decimal) {
        queue.sync(flags: .barrier) {
            let envelope = _loadEnvelope() ?? CacheEnvelope(providers: [:], baselines: [:], transcripts: [:])
            let today = TodayHelper.formatYYYYMMDD(now)
            let existing = envelope.dailyUsage[id]

            // Rollover: cold start or new calendar day → reset to this poll's delta.
            // Same day → add the delta to the running total.
            let newTokens: Int
            let newCost: Decimal
            if existing == nil || existing!.date != today {
                newTokens = deltaTokens
                newCost = deltaCostUSD
            } else {
                newTokens = existing!.tokens + deltaTokens
                newCost = existing!.costUSD + deltaCostUSD
            }

            let record = DailyUsageRecord(date: today, tokens: newTokens, costUSD: newCost)
            var updated = envelope.dailyUsage
            updated[id] = record
            _writeEnvelope(CacheEnvelope(
                schemaVersion: 3,
                providers: envelope.providers,
                baselines: envelope.baselines,
                transcripts: envelope.transcripts,
                dailyUsage: updated
            ))
            return (newTokens, newCost)
        }
    }

    // MARK: - Private helpers (call only from within `queue`)

    private func _loadEnvelope() -> CacheEnvelope? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Try schemaVersion 3 first (fast path — the normal case after first write).
        if let v3 = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
           v3.schemaVersion == 3 {
            return v3
        }

        // v2 → v3 migration: decode v2 shape, synthesise v3 with empty dailyUsage.
        // The accumulator self-heals on the next poll (today's partial total restarts).
        if let v2 = try? JSONDecoder().decode(CacheEnvelopeV2.self, from: data),
           v2.schemaVersion == 2 {
            logger.notice("cache schemaVersion 2 → 3 migrated (dailyUsage: empty)")
            return CacheEnvelope(
                schemaVersion: 3,
                providers: v2.providers,
                baselines: v2.baselines,
                transcripts: v2.transcripts,
                dailyUsage: [:]
            )
        }

        // v1 → v3 migration: decode v1 shape, synthesise v3 with empty transcripts + dailyUsage.
        // This path runs exactly once per installation — subsequent writes are v3.
        if let v1 = try? JSONDecoder().decode(CacheEnvelopeV1.self, from: data),
           v1.schemaVersion == 1 {
            logger.notice("cache schemaVersion 1 → 3 migrated (transcripts + dailyUsage: empty)")
            return CacheEnvelope(
                schemaVersion: 3,
                providers: v1.providers,
                baselines: v1.baselines,
                transcripts: [:],
                dailyUsage: [:]
            )
        }

        // schemaVersion 0, >3, or unknown — cold-start without crashing (D-09).
        logger.warning("cache decode failed; cold-start")
        return nil
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

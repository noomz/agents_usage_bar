import Foundation

/// A record of a provider's cumulative-metric baseline for one calendar day.
///
/// Used by `FileCacheStore.maintainBaseline` to implement the D-01..D-05
/// baseline-delta approach: `costToday = current(total_usage) − baseline.value`.
///
/// D-02: `date` is stored as a `"YYYY-MM-DD"` string in the user's local calendar
/// (produced by `TodayHelper.formatYYYYMMDD`) so midnight rollover detection is
/// timezone-correct even across DST transitions.
public struct BaselineRecord: Sendable, Codable, Equatable {
    /// The `total_usage` value captured at the start of the current day (D-01).
    public let value: Double

    /// The calendar date this baseline was set, as `"YYYY-MM-DD"` in local time (D-02).
    public let date: String

    /// The most recent `total_usage` value seen during today's session.
    /// Used by the provider to compute `costToday = lastValue − value`.
    public let lastValue: Double

    /// Timestamp of the last call to `maintainBaseline` that updated `lastValue`.
    public let lastUpdated: Date

    public init(value: Double, date: String, lastValue: Double, lastUpdated: Date) {
        self.value = value
        self.date = date
        self.lastValue = lastValue
        self.lastUpdated = lastUpdated
    }
}

/// Protocol seam for persisted provider state and baseline data.
///
/// `FileCacheStore` is the production implementation.
/// Tests can inject an in-memory conformance or use `FileCacheStore(testingRootURL:)`.
public protocol CacheStore: Sendable {

    /// Returns all persisted `ProviderState` values, or an empty dict on cold launch
    /// or schema mismatch (D-09 fail-soft).
    func loadAll() -> [ProviderID: ProviderState]

    /// Atomically persists the current provider state dict (D-08).
    func save(_ providers: [ProviderID: ProviderState])

    /// Returns the `BaselineRecord` for `id` if one exists for `now`'s calendar day,
    /// or `nil` if no baseline has been recorded (D-03 cold-launch case).
    func baseline(for id: ProviderID, on now: Date) -> BaselineRecord?

    /// Updates the baseline for `id` following the D-04/D-05 rules:
    /// - Cold start or new day → record `currentValue` as new baseline.
    /// - Same day, positive delta → keep baseline, update `lastValue`.
    /// - Same day, negative delta → log warning and reset baseline (D-04).
    func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double)

    // MARK: - Transcript offset methods (Plan 02.01 — CLAUDE-02)
    //
    // These three methods store and retrieve per-file JSONL byte-offset cursors,
    // persisted in the FileCacheStore envelope schemaVersion 2.
    //
    // v1 → v2 migration: a v1 envelope on disk is automatically upgraded on first
    // load; existing `providers` and `baselines` are preserved (HIGH-risk migration
    // mitigated — see RESEARCH §A schemaVersion bump risk: HIGH).

    /// Returns the persisted `TranscriptOffset` for `urlString`, or `nil` if none exists.
    func transcriptOffset(forURL urlString: String) -> TranscriptOffset?

    /// Upserts `offset` into the transcript map keyed by `offset.url`.
    /// Overwrites any prior offset stored for the same URL (delta semantics — CLAUDE-02).
    func setTranscriptOffset(_ offset: TranscriptOffset)

    /// Batch-upserts multiple transcript offsets in a single envelope read/write.
    /// Per-poll fan-outs can produce hundreds of offsets — calling
    /// `setTranscriptOffset` per file is O(N²) (each call re-decodes/encodes the full
    /// envelope). Production `FileCacheStore` overrides this for an atomic single
    /// write; the default extension implementation below falls back to per-offset
    /// calls so in-memory test stores stay simple.
    func setTranscriptOffsets(_ offsets: [TranscriptOffset])

    /// Returns a snapshot of all persisted transcript offsets.
    /// Mutating the returned dict has no side effect (Swift value-type copy).
    func allTranscriptOffsets() -> [String: TranscriptOffset]
}

extension CacheStore {
    /// Default fan-out implementation. Conformers that can do a single atomic write
    /// (e.g. `FileCacheStore`) should override this.
    public func setTranscriptOffsets(_ offsets: [TranscriptOffset]) {
        for offset in offsets {
            setTranscriptOffset(offset)
        }
    }
}

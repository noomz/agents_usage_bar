import Foundation
import os

// MARK: - NotificationStateRecord

/// Per-(provider, day) FSM state persisted to UserDefaults under key
/// `notif.<providerID>.<yyyy-MM-dd>` (NOTIF-04).
///
/// - `lastBand` — highest `ThresholdBand` the engine has emitted a decision for on this day.
/// - `snoozedUntilDay` — when set to today's `yyyy-MM-dd` string, suppresses ALL further
///   notification bands for this provider until local-midnight rollover (NOTIF-05 +
///   default decision #2: snooze suppresses every band, not just the band that was
///   showing when the user tapped Snooze).
public struct NotificationStateRecord: Sendable, Codable, Equatable {
    public let lastBand: ThresholdBand
    public let snoozedUntilDay: String?

    public init(lastBand: ThresholdBand, snoozedUntilDay: String?) {
        self.lastBand = lastBand
        self.snoozedUntilDay = snoozedUntilDay
    }
}

// MARK: - NotificationStateStorage

/// Storage protocol seam for the per-(provider, day) FSM state used by Plan 02.05.
///
/// Implementations:
/// - `UserDefaultsNotificationStateStore` — production backing.
/// - `InMemoryNotificationStateStore` — test double.
///
/// Note: this is intentionally a THIN UserDefaults shim, not a peer of `CacheStore`
/// (NOT a B9 / NoopCacheStore-style abstraction). It serves only the notification FSM.
public protocol NotificationStateStorage: Sendable {
    /// Returns the stored record for `(providerID, day)` or `nil` if absent / undecodable.
    func record(forProviderID id: ProviderID, day: String) -> NotificationStateRecord?

    /// Writes the record for `(providerID, day)`. Overwrites any prior record.
    func setRecord(_ record: NotificationStateRecord, forProviderID id: ProviderID, day: String)

    /// Returns every `(providerID, record)` pair stored for the given `today` day-string.
    func allRecordsForToday(_ today: String) -> [(ProviderID, NotificationStateRecord)]

    /// Removes every record whose stored day is older than `(today - retentionDays)`.
    /// Recommended `retentionDays = 7`. Called once at app launch from `AppDependencies.makeProduction()`.
    func pruneOldKeys(olderThan retentionDays: Int, today: String)
}

// MARK: - UserDefaultsNotificationStateStore

/// Production storage backed by `UserDefaults`. Each record is JSON-encoded and stored
/// under key `"\(keyPrefix)\(providerID.rawValue).\(day)"`, e.g. `notif.openrouter.2026-05-13`.
///
/// `@unchecked Sendable` is safe — `UserDefaults` is itself thread-safe, and the only
/// mutable state is the immutable `defaults` / `keyPrefix` references.
public final class UserDefaultsNotificationStateStore: NotificationStateStorage, @unchecked Sendable {

    private let defaults: UserDefaults
    private let keyPrefix: String
    private let logger = AppLogger.logger(category: "notify")

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "notif.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func record(forProviderID id: ProviderID, day: String) -> NotificationStateRecord? {
        guard let data = defaults.data(forKey: key(for: id, day: day)) else { return nil }
        return try? JSONDecoder().decode(NotificationStateRecord.self, from: data)
    }

    public func setRecord(_ record: NotificationStateRecord, forProviderID id: ProviderID, day: String) {
        guard let data = try? JSONEncoder().encode(record) else {
            logger.error("notify state encode failed for \(id.rawValue, privacy: .public)")
            return
        }
        defaults.set(data, forKey: key(for: id, day: day))
    }

    public func allRecordsForToday(_ today: String) -> [(ProviderID, NotificationStateRecord)] {
        var out: [(ProviderID, NotificationStateRecord)] = []
        let suffix = ".\(today)"
        for (rawKey, value) in defaults.dictionaryRepresentation() {
            guard rawKey.hasPrefix(keyPrefix), rawKey.hasSuffix(suffix),
                  let data = value as? Data,
                  let record = try? JSONDecoder().decode(NotificationStateRecord.self, from: data)
            else { continue }
            // Key layout: "<keyPrefix><pid.rawValue>.<yyyy-MM-dd>"
            let withoutPrefix = String(rawKey.dropFirst(keyPrefix.count))
            let pidPart = withoutPrefix.dropLast(suffix.count)
            guard !pidPart.isEmpty else { continue }
            out.append((ProviderID(rawValue: String(pidPart)), record))
        }
        return out
    }

    public func pruneOldKeys(olderThan retentionDays: Int, today: String) {
        let cal = Calendar.current
        guard let todayDate = cal.date(from: ymdComponents(today)),
              let cutoff = cal.date(byAdding: .day, value: -retentionDays, to: todayDate)
        else { return }

        for rawKey in defaults.dictionaryRepresentation().keys where rawKey.hasPrefix(keyPrefix) {
            guard rawKey.count > 10 else { continue }
            let dateStr = String(rawKey.suffix(10))
            let comps = ymdComponents(dateStr)
            guard comps.year != nil, comps.month != nil, comps.day != nil,
                  let date = cal.date(from: comps),
                  date < cutoff
            else { continue }
            defaults.removeObject(forKey: rawKey)
        }
    }

    // MARK: - Private helpers

    private func key(for id: ProviderID, day: String) -> String {
        "\(keyPrefix)\(id.rawValue).\(day)"
    }

    private func ymdComponents(_ s: String) -> DateComponents {
        var comps = DateComponents()
        let parts = s.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return comps }
        comps.year = year
        comps.month = month
        comps.day = day
        return comps
    }
}

// MARK: - InMemoryNotificationStateStore

/// In-memory storage for tests. Mirrors `UserDefaultsNotificationStateStore` semantics
/// without JSON round-tripping.
///
/// `@unchecked Sendable` is safe — Swift Testing runs each `@Test async func` in its own
/// structured-concurrency scope; no concurrent mutation occurs within a single test (B7
/// pattern from `FakeUNUserNotificationCenter`).
public final class InMemoryNotificationStateStore: NotificationStateStorage, @unchecked Sendable {

    /// Stored entries keyed by `"\(providerID.rawValue).\(day)"`.
    private var entries: [String: NotificationStateRecord] = [:]

    public init() {}

    public func record(forProviderID id: ProviderID, day: String) -> NotificationStateRecord? {
        entries[key(for: id, day: day)]
    }

    public func setRecord(_ record: NotificationStateRecord, forProviderID id: ProviderID, day: String) {
        entries[key(for: id, day: day)] = record
    }

    public func allRecordsForToday(_ today: String) -> [(ProviderID, NotificationStateRecord)] {
        var out: [(ProviderID, NotificationStateRecord)] = []
        let suffix = ".\(today)"
        for (rawKey, record) in entries where rawKey.hasSuffix(suffix) {
            let pidPart = rawKey.dropLast(suffix.count)
            guard !pidPart.isEmpty else { continue }
            out.append((ProviderID(rawValue: String(pidPart)), record))
        }
        return out
    }

    public func pruneOldKeys(olderThan retentionDays: Int, today: String) {
        let cal = Calendar.current
        guard let todayDate = cal.date(from: ymdComponents(today)),
              let cutoff = cal.date(byAdding: .day, value: -retentionDays, to: todayDate)
        else { return }

        let toRemove: [String] = entries.keys.compactMap { rawKey in
            guard rawKey.count > 10 else { return nil }
            let dateStr = String(rawKey.suffix(10))
            let comps = ymdComponents(dateStr)
            guard comps.year != nil, comps.month != nil, comps.day != nil,
                  let date = cal.date(from: comps),
                  date < cutoff
            else { return nil }
            return rawKey
        }
        for key in toRemove { entries.removeValue(forKey: key) }
    }

    // MARK: - Private helpers

    private func key(for id: ProviderID, day: String) -> String {
        "\(id.rawValue).\(day)"
    }

    private func ymdComponents(_ s: String) -> DateComponents {
        var comps = DateComponents()
        let parts = s.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return comps }
        comps.year = year
        comps.month = month
        comps.day = day
        return comps
    }
}

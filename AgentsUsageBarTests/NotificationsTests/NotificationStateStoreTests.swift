import Testing
import Foundation
@testable import AgentsUsageBar

/// Plan 02.05 — covers `NotificationStateStorage` semantics against both implementations
/// (`InMemoryNotificationStateStore` and `UserDefaultsNotificationStateStore`).
@Suite("NotificationStateStoreTests")
struct NotificationStateStoreTests {

    // MARK: - Fixtures

    static let pidA = ProviderID(rawValue: "openrouter")
    static let pidB = ProviderID(rawValue: "claude")

    static let today = "2026-05-13"
    static let yesterday = "2026-05-12"
    static let weekAgo = "2026-05-06"
    static let twoWeeksAgo = "2026-04-29"

    func makeRecord(band: ThresholdBand = .warning, snoozedUntilDay: String? = nil) -> NotificationStateRecord {
        NotificationStateRecord(lastBand: band, snoozedUntilDay: snoozedUntilDay)
    }

    /// Creates an isolated `UserDefaults` instance per test so global state never leaks.
    func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suite = "test.aub.notif.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    func clearDefaults(_ defaults: UserDefaults, suite: String) {
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - InMemoryNotificationStateStore

    @Test("InMemory: fresh store returns nil")
    func inMemory_freshStore_recordReturnsNil() {
        let store = InMemoryNotificationStateStore()
        #expect(store.record(forProviderID: Self.pidA, day: Self.today) == nil)
    }

    @Test("InMemory: setRecord then read returns the same value")
    func inMemory_setRecord_thenRead_returnsSame() {
        let store = InMemoryNotificationStateStore()
        let record = makeRecord(band: .warning, snoozedUntilDay: nil)
        store.setRecord(record, forProviderID: Self.pidA, day: Self.today)
        #expect(store.record(forProviderID: Self.pidA, day: Self.today) == record)
    }

    @Test("InMemory: setRecord overwrites prior entry for the same (provider, day)")
    func inMemory_setRecord_overwrites() {
        let store = InMemoryNotificationStateStore()
        store.setRecord(makeRecord(band: .warning, snoozedUntilDay: nil), forProviderID: Self.pidA, day: Self.today)
        let updated = makeRecord(band: .critical, snoozedUntilDay: Self.today)
        store.setRecord(updated, forProviderID: Self.pidA, day: Self.today)
        #expect(store.record(forProviderID: Self.pidA, day: Self.today) == updated)
    }

    @Test("InMemory: allRecordsForToday filters by day, ignores other-day entries")
    func inMemory_allRecordsForToday_filtersByDay() {
        let store = InMemoryNotificationStateStore()
        store.setRecord(makeRecord(band: .warning), forProviderID: Self.pidA, day: Self.today)
        store.setRecord(makeRecord(band: .critical), forProviderID: Self.pidB, day: Self.today)
        store.setRecord(makeRecord(band: .exceeded), forProviderID: Self.pidA, day: Self.yesterday)

        let todayRecords = store.allRecordsForToday(Self.today)
        #expect(todayRecords.count == 2)
        let pids = Set(todayRecords.map(\.0))
        #expect(pids == [Self.pidA, Self.pidB])
        let bands = Set(todayRecords.map(\.1.lastBand))
        #expect(bands == [.warning, .critical])
    }

    @Test("InMemory: pruneOldKeys removes entries older than retentionDays")
    func inMemory_pruneOldKeys_removesEntriesOlderThan7d() {
        let store = InMemoryNotificationStateStore()
        store.setRecord(makeRecord(band: .warning), forProviderID: Self.pidA, day: Self.today)
        store.setRecord(makeRecord(band: .warning), forProviderID: Self.pidA, day: Self.yesterday)
        store.setRecord(makeRecord(band: .warning), forProviderID: Self.pidA, day: Self.weekAgo)
        store.setRecord(makeRecord(band: .warning), forProviderID: Self.pidA, day: Self.twoWeeksAgo)

        store.pruneOldKeys(olderThan: 7, today: Self.today)

        #expect(store.record(forProviderID: Self.pidA, day: Self.today) != nil)
        #expect(store.record(forProviderID: Self.pidA, day: Self.yesterday) != nil)
        // 7 days back is exactly the cutoff — that record stays.
        #expect(store.record(forProviderID: Self.pidA, day: Self.weekAgo) != nil)
        // 14 days back is definitely pruned.
        #expect(store.record(forProviderID: Self.pidA, day: Self.twoWeeksAgo) == nil)
    }

    // MARK: - UserDefaultsNotificationStateStore

    @Test("UserDefaults: fresh store returns nil")
    func userDefaults_freshStore_recordReturnsNil() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { clearDefaults(defaults, suite: suite) }
        let store = UserDefaultsNotificationStateStore(defaults: defaults)
        #expect(store.record(forProviderID: Self.pidA, day: Self.today) == nil)
    }

    @Test("UserDefaults: setRecord then read returns the same value (JSON round-trip)")
    func userDefaults_setRecord_thenRead_returnsSame() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { clearDefaults(defaults, suite: suite) }
        let store = UserDefaultsNotificationStateStore(defaults: defaults)
        let record = makeRecord(band: .critical, snoozedUntilDay: Self.today)
        store.setRecord(record, forProviderID: Self.pidA, day: Self.today)
        #expect(store.record(forProviderID: Self.pidA, day: Self.today) == record)
    }

    @Test("UserDefaults: setRecord overwrites prior entry")
    func userDefaults_setRecord_overwrites() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { clearDefaults(defaults, suite: suite) }
        let store = UserDefaultsNotificationStateStore(defaults: defaults)
        store.setRecord(makeRecord(band: .warning), forProviderID: Self.pidA, day: Self.today)
        let updated = makeRecord(band: .exceeded, snoozedUntilDay: Self.today)
        store.setRecord(updated, forProviderID: Self.pidA, day: Self.today)
        #expect(store.record(forProviderID: Self.pidA, day: Self.today) == updated)
    }

    @Test("UserDefaults: allRecordsForToday returns 2 of 3 when 1 entry is yesterday")
    func userDefaults_allRecordsForToday_filtersByDay() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { clearDefaults(defaults, suite: suite) }
        let store = UserDefaultsNotificationStateStore(defaults: defaults)
        store.setRecord(makeRecord(band: .warning), forProviderID: Self.pidA, day: Self.today)
        store.setRecord(makeRecord(band: .critical), forProviderID: Self.pidB, day: Self.today)
        store.setRecord(makeRecord(band: .exceeded), forProviderID: Self.pidA, day: Self.yesterday)

        let records = store.allRecordsForToday(Self.today)
        #expect(records.count == 2)
        let pids = Set(records.map(\.0))
        #expect(pids == [Self.pidA, Self.pidB])
    }

    @Test("UserDefaults: pruneOldKeys removes only entries older than retentionDays")
    func userDefaults_pruneOldKeys_removesEntriesOlderThan7d() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { clearDefaults(defaults, suite: suite) }
        let store = UserDefaultsNotificationStateStore(defaults: defaults)
        store.setRecord(makeRecord(band: .warning), forProviderID: Self.pidA, day: Self.today)
        store.setRecord(makeRecord(band: .warning), forProviderID: Self.pidA, day: Self.weekAgo)
        store.setRecord(makeRecord(band: .warning), forProviderID: Self.pidA, day: Self.twoWeeksAgo)

        store.pruneOldKeys(olderThan: 7, today: Self.today)

        #expect(store.record(forProviderID: Self.pidA, day: Self.today) != nil)
        #expect(store.record(forProviderID: Self.pidA, day: Self.weekAgo) != nil)
        #expect(store.record(forProviderID: Self.pidA, day: Self.twoWeeksAgo) == nil)
    }

    @Test("UserDefaults: key format is 'notif.<rawValue>.<yyyy-MM-dd>' (source contract check)")
    func userDefaults_keyFormat_contract() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { clearDefaults(defaults, suite: suite) }
        let store = UserDefaultsNotificationStateStore(defaults: defaults)
        store.setRecord(makeRecord(band: .warning), forProviderID: Self.pidA, day: Self.today)
        // Raw key must match the documented contract; downstream tooling (Console.app
        // inspection, support scripts) depends on the literal `notif.<pid>.<day>` shape.
        let expectedKey = "notif.openrouter.\(Self.today)"
        #expect(defaults.data(forKey: expectedKey) != nil)
    }
}

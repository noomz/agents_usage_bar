import Testing
import Foundation
import SwiftUI
@testable import AgentsUsageBar

/// Plan 02.07 — UI-08 (`isStale`) + UI-09 (`maxQuotaFraction` + `menuBarTint`).
///
/// These tests exercise the new computed properties directly via the `@MainActor` store.
/// They do NOT drive a full `refresh()` — staleness and tint are pure functions of the
/// in-memory `providers` map + the current refresh interval, so we seed state via
/// `seedPlaceholder`/`refresh` and assert the computed surfaces.
@MainActor
@Suite("AggregateStoreStaleAndTintTests")
struct AggregateStoreStaleAndTintTests {

    // MARK: - Helpers

    static let pidA = ProviderID(rawValue: "providerA")
    static let pidB = ProviderID(rawValue: "providerB")
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Provider that always returns a fixed snapshot — used to drive `refresh` so the store
    /// populates `lastSuccess` with a real timestamp.
    final actor SeedFakeProvider: UsageProvider {
        nonisolated let id: ProviderID
        nonisolated let displayName: String
        nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
            hasQuota: true, hasCost: true, hasTokens: false, isLocal: false
        )

        private let snapshot: UsageSnapshot

        init(id: ProviderID, snapshot: UsageSnapshot) {
            self.id = id
            self.displayName = id.rawValue
            self.snapshot = snapshot
        }

        func status() -> ProviderStatus { .ok(lastSuccess: Date()) }
        func fetch(now: Date) async throws -> UsageSnapshot { snapshot }
    }

    private static func snapshot(
        for id: ProviderID,
        quota: Quota? = nil,
        windows: [QuotaWindow]? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: quota,
            raw: [:],
            quotaWindows: windows
        )
    }

    private static func makeStore() -> AggregateStore {
        AggregateStore(
            registry: [],
            clock: VirtualClock(fixed: now),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
    }

    /// Drives a single refresh of the store via a `SeedFakeProvider` that returns the given
    /// snapshot for `providerID`, so `lastSuccess` is wired and `providers[id].snapshot`
    /// holds the supplied data.
    private static func storeWithSeededProvider(
        id: ProviderID,
        snapshot snap: UsageSnapshot,
        interval: RefreshInterval = .m5,
        refreshAt: Date
    ) async -> AggregateStore {
        let provider = SeedFakeProvider(id: id, snapshot: snap)
        let store = AggregateStore(
            registry: [provider],
            clock: VirtualClock(fixed: refreshAt),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        store.setRefreshInterval(interval)
        await store.refresh(now: refreshAt)
        return store
    }

    // MARK: - isStale (UI-08)

    @Test("isStale returns false when provider has no lastSuccess")
    func isStale_noLastSuccess_returnsFalse() {
        let store = Self.makeStore()
        store.seedPlaceholder(providerID: Self.pidA, displayName: "Provider A")
        #expect(store.isStale(Self.pidA, now: Self.now) == false)
    }

    @Test("isStale returns false when lastSuccess is recent (well within interval)")
    func isStale_recent_lastSuccess_returnsFalse() async {
        let snap = Self.snapshot(for: Self.pidA)
        let refreshAt = Self.now
        let store = await Self.storeWithSeededProvider(
            id: Self.pidA, snapshot: snap, interval: .m5, refreshAt: refreshAt
        )
        // 100s after the refresh — well below the 2 × 300s = 600s stale threshold.
        #expect(store.isStale(Self.pidA, now: refreshAt.addingTimeInterval(100)) == false)
    }

    @Test("isStale returns false when lastSuccess is just under 2× interval (599s for .m5)")
    func isStale_lastSuccess_just_under_2x_returnsFalse() async {
        let snap = Self.snapshot(for: Self.pidA)
        let refreshAt = Self.now
        let store = await Self.storeWithSeededProvider(
            id: Self.pidA, snapshot: snap, interval: .m5, refreshAt: refreshAt
        )
        #expect(store.isStale(Self.pidA, now: refreshAt.addingTimeInterval(599)) == false)
    }

    @Test("isStale returns true when lastSuccess exceeds 2× interval (700s for .m5)")
    func isStale_lastSuccess_above_2x_returnsTrue() async {
        let snap = Self.snapshot(for: Self.pidA)
        let refreshAt = Self.now
        let store = await Self.storeWithSeededProvider(
            id: Self.pidA, snapshot: snap, interval: .m5, refreshAt: refreshAt
        )
        #expect(store.isStale(Self.pidA, now: refreshAt.addingTimeInterval(700)) == true)
    }

    @Test("isStale returns false on .manual interval — manual refresh has no cadence")
    func isStale_manualInterval_returnsFalse() async {
        let snap = Self.snapshot(for: Self.pidA)
        let refreshAt = Self.now
        let store = await Self.storeWithSeededProvider(
            id: Self.pidA, snapshot: snap, interval: .m5, refreshAt: refreshAt
        )
        // Switch to manual — even an hour later, isStale must be false.
        store.setRefreshInterval(.manual)
        #expect(store.isStale(Self.pidA, now: refreshAt.addingTimeInterval(3600)) == false)
    }

    // MARK: - maxQuotaFraction (UI-09)

    @Test("maxQuotaFraction returns 0 when no providers are seeded")
    func maxQuotaFraction_emptyProviders_returns0() {
        let store = Self.makeStore()
        #expect(store.maxQuotaFraction == 0)
    }

    @Test("maxQuotaFraction returns the provider's primary quota fraction when no windows")
    func maxQuotaFraction_singleProviderQuotaOnly() async {
        let snap = Self.snapshot(
            for: Self.pidA,
            quota: Quota(used: 6.0, limit: 10.0, remaining: 4.0)
        )
        let store = await Self.storeWithSeededProvider(
            id: Self.pidA, snapshot: snap, refreshAt: Self.now
        )
        #expect(abs(store.maxQuotaFraction - 0.6) < 1e-9)
    }

    @Test("maxQuotaFraction returns the max quotaWindow utilization when no primary quota")
    func maxQuotaFraction_singleProviderQuotaWindowOnly() async {
        let snap = Self.snapshot(
            for: Self.pidA,
            windows: [QuotaWindow(name: "5h", utilization: 0.85, resetsAt: nil)]
        )
        let store = await Self.storeWithSeededProvider(
            id: Self.pidA, snapshot: snap, refreshAt: Self.now
        )
        #expect(abs(store.maxQuotaFraction - 0.85) < 1e-9)
    }

    @Test("maxQuotaFraction returns the global max across providers (0.3 vs 0.92 → 0.92)")
    func maxQuotaFraction_multipleProviders_returnsMax() async {
        let snapA = Self.snapshot(
            for: Self.pidA,
            quota: Quota(used: 3.0, limit: 10.0, remaining: 7.0)
        )
        let snapB = Self.snapshot(
            for: Self.pidB,
            windows: [QuotaWindow(name: "7d", utilization: 0.92, resetsAt: nil)]
        )
        let provA = SeedFakeProvider(id: Self.pidA, snapshot: snapA)
        let provB = SeedFakeProvider(id: Self.pidB, snapshot: snapB)
        let store = AggregateStore(
            registry: [provA, provB],
            clock: VirtualClock(fixed: Self.now),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        await store.refresh(now: Self.now)
        #expect(abs(store.maxQuotaFraction - 0.92) < 1e-9)
    }

    @Test("maxQuotaFraction per-provider takes max(primary, windows) — (0.4, 0.78, 0.65) → 0.78")
    func maxQuotaFraction_perProviderTakesMaxOfQuotaAndWindows() async {
        let snap = Self.snapshot(
            for: Self.pidA,
            quota: Quota(used: 4.0, limit: 10.0, remaining: 6.0),
            windows: [
                QuotaWindow(name: "5h", utilization: 0.78, resetsAt: nil),
                QuotaWindow(name: "7d", utilization: 0.65, resetsAt: nil)
            ]
        )
        let store = await Self.storeWithSeededProvider(
            id: Self.pidA, snapshot: snap, refreshAt: Self.now
        )
        #expect(abs(store.maxQuotaFraction - 0.78) < 1e-9)
    }

    // MARK: - menuBarTint (UI-09)

    @Test("menuBarTint == .green when maxQuotaFraction is below 0.80 (e.g. 0.75)")
    func menuBarTint_green_below_80_percent() async {
        let snap = Self.snapshot(
            for: Self.pidA,
            quota: Quota(used: 7.5, limit: 10.0, remaining: 2.5)
        )
        let store = await Self.storeWithSeededProvider(
            id: Self.pidA, snapshot: snap, refreshAt: Self.now
        )
        #expect(store.menuBarTint == Color.green)
    }

    @Test("menuBarTint == .yellow when maxQuotaFraction is exactly 0.80")
    func menuBarTint_yellow_at_80() async {
        let snap = Self.snapshot(
            for: Self.pidA,
            quota: Quota(used: 8.0, limit: 10.0, remaining: 2.0)
        )
        let store = await Self.storeWithSeededProvider(
            id: Self.pidA, snapshot: snap, refreshAt: Self.now
        )
        #expect(store.menuBarTint == Color.yellow)
    }

    @Test("menuBarTint == .red when maxQuotaFraction is exactly 0.95")
    func menuBarTint_red_at_95() async {
        let snap = Self.snapshot(
            for: Self.pidA,
            quota: Quota(used: 9.5, limit: 10.0, remaining: 0.5)
        )
        let store = await Self.storeWithSeededProvider(
            id: Self.pidA, snapshot: snap, refreshAt: Self.now
        )
        #expect(store.menuBarTint == Color.red)
    }

    @Test("menuBarTint == .red for quotaWindow over 100% (saturation)")
    func menuBarTint_red_above_100() async {
        // Quota.fraction clamps to [0, 1] but quotaWindow.utilization is uncapped — Plan 02.04
        // normalises 0–100 to 0.0–1.0 but pathological "overage" servers can still send > 1.0.
        let snap = Self.snapshot(
            for: Self.pidA,
            windows: [QuotaWindow(name: "5h", utilization: 1.10, resetsAt: nil)]
        )
        let store = await Self.storeWithSeededProvider(
            id: Self.pidA, snapshot: snap, refreshAt: Self.now
        )
        #expect(store.menuBarTint == Color.red)
    }

    @Test("menuBarTint == .green when no providers are seeded (default healthy state)")
    func menuBarTint_green_emptyProviders() {
        let store = Self.makeStore()
        #expect(store.maxQuotaFraction == 0)
        #expect(store.menuBarTint == Color.green)
    }
}

import Observation
import Foundation

/// @Observable @MainActor aggregation store — the single source of truth for the UI.
///
/// Orchestrates per-provider fetch fan-out via `withTaskGroup`, applies snapshots on MainActor,
/// persists the cache atomically after each successful refresh, and dispatches to
/// `ThresholdEngine` + `NotificationManager`.
///
/// **Plan 01.05 replaces the Phase 0 stub** (Plan 01.01) with the full implementation:
/// - `refresh(now:)` fans out via `withTaskGroup`, coalesces concurrent callers, applies 5s skip.
/// - `seedPlaceholder(providerID:displayName:status:)` pre-populates state for cold-launch UI (B10).
/// - `setRefreshInterval(_:)` stub — consumed by PollScheduler in Task 2 / Plan 01.08 composition.
///
/// **W4:** `ProviderState` is OWNED by `Domain/ProviderState.swift` (Plan 01.02).
/// This file IMPORTS it — no duplicate `Aggregation/ProviderState.swift`.
@Observable
@MainActor
public final class AggregateStore {

    // MARK: - Public observable state

    /// Per-provider UI state keyed by stable `ProviderID`.
    /// Seeded from cache on init (UI-07: no "Loading…" flash on relaunch).
    public private(set) var providers: [ProviderID: ProviderState] = [:]

    /// Rolled-up totals across all providers for today.
    public private(set) var totals: DailyTotals = .zero

    /// Timestamp of the last completed refresh tick. `nil` before the first poll.
    public private(set) var lastTick: Date?

    // MARK: - Dependencies

    private let registry: [any UsageProvider]
    private let clock: any Clock
    private let cache: any CacheStore
    private let thresholds: ThresholdEngine
    private let notifications: any NotificationManager

    // MARK: - Coalescing state

    /// Tracks the in-flight refresh task so concurrent callers can await it rather than
    /// launching a second fan-out (POLL-03 coalesce).
    private var currentRefresh: Task<Void, Never>?

    // MARK: - Interval state (stub — consumed by PollScheduler / Plan 01.08)

    private var currentInterval: RefreshInterval = .m5

    // MARK: - Init

    /// Creates the store, immediately loading cached provider state so the UI shows
    /// prior data on first open without a "Loading…" flash (UI-07).
    public init(
        registry: [any UsageProvider],
        clock: any Clock,
        cache: any CacheStore,
        thresholds: ThresholdEngine,
        notifications: any NotificationManager
    ) {
        self.registry = registry
        self.clock = clock
        self.cache = cache
        self.thresholds = thresholds
        self.notifications = notifications

        // UI-07: seed from cache synchronously before any view reads occur.
        self.providers = cache.loadAll()
        rollupTotals()
    }

    // MARK: - Public API

    /// Fans out fetch to all registered providers concurrently via `withTaskGroup`.
    ///
    /// Coalescing rules (POLL-03):
    /// 1. If a refresh is already in flight, await it and return immediately.
    /// 2. If `now − lastTick < 5s`, skip entirely (debounce for popover-open triggers).
    public func refresh(now: Date) async {
        // Rule 1: coalesce — if a refresh is already running, wait for it
        if let existing = currentRefresh {
            await existing.value
            return
        }

        // Rule 2: 5-second skip
        if let last = lastTick, now.timeIntervalSince(last) < 5 {
            return
        }

        // Launch the refresh task and track it for coalescing.
        // Use an unowned capture instead of weak to get Task<Void, Never> (not Task<Void?, Never>).
        let task = Task { [unowned self] in
            await self.performRefresh(now: now)
        }
        currentRefresh = task
        await task.value
        currentRefresh = nil
    }

    /// Pre-populates a placeholder `ProviderState` so the UI shows a row immediately
    /// without waiting for the first poll (B10).
    ///
    /// Called by `AppDependencies.makeProduction()` (Plan 01.08) when no API key is configured,
    /// so the row shows "OpenRouter — not configured" instead of being absent.
    public func seedPlaceholder(
        providerID: ProviderID,
        displayName: String,
        status: ProviderStatus = .unauthenticated
    ) {
        providers[providerID] = ProviderState.placeholder(
            providerID: providerID,
            displayName: displayName,
            status: status
        )
        rollupTotals()
    }

    /// Stub for interval propagation — consumed by `PollScheduler` (Task 2) and
    /// wired in the composition root (Plan 01.08).
    public func setRefreshInterval(_ interval: RefreshInterval) {
        currentInterval = interval
    }

    // MARK: - Private refresh logic

    private func performRefresh(now: Date) async {
        await withTaskGroup(of: (ProviderID, Result<UsageSnapshot, Error>).self) { group in
            for p in registry {
                group.addTask {
                    do {
                        return (p.id, .success(try await p.fetch(now: now)))
                    } catch {
                        return (p.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                apply(result, for: id, now: now)
            }
        }

        lastTick = now
        rollupTotals()
        await fireThresholdNotificationsIfNeeded(now: now)
        cache.save(providers)
    }

    /// Applies a per-provider fetch result, updating the provider's `ProviderState`.
    private func apply(_ result: Result<UsageSnapshot, Error>, for id: ProviderID, now: Date) {
        switch result {
        case .success(let snap):
            if let existing = providers[id] {
                providers[id] = existing.applying(snapshot: snap, at: now)
            } else {
                providers[id] = ProviderState.initial(snapshot: snap, at: now)
            }
        case .failure(let error):
            if let existing = providers[id] {
                providers[id] = existing.applyingError(error, at: now)
            } else {
                providers[id] = ProviderState.initialError(error, at: now)
            }
        }
    }

    /// Sums `costTodayUSD` and `tokensToday` across all provider snapshots.
    /// `nil` tokens treated as 0 (OpenRouter does not report token counts in Phase 1).
    private func rollupTotals() {
        var totalTokens = 0
        var totalCost: Decimal = 0
        for state in providers.values {
            guard let snap = state.snapshot else { continue }
            totalTokens += snap.tokensToday ?? 0
            if let cost = snap.costTodayUSD {
                totalCost += cost
            }
        }
        totals = DailyTotals(tokens: totalTokens, costUSD: totalCost)
    }

    /// Calls `ThresholdEngine.decisions` and dispatches results to `NotificationManager`.
    /// Plan 01.07 fills in the real engine; the stub returns `[]` so this is a no-op in Phase 1.
    private func fireThresholdNotificationsIfNeeded(now: Date) async {
        let snapshots = providers.values.compactMap(\.snapshot)
        let decisions = thresholds.decisions(for: snapshots, now: now, snoozedUntil: [:])
        await notifications.schedule(decisions)
    }
}

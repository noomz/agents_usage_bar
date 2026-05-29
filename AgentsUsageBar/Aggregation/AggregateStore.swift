import Observation
import Foundation
import SwiftUI

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
    /// Authoritative displayName per provider, derived from the registry at init.
    /// Used to overlay stale displayNames cached from older builds (e.g. lowercase
    /// "claude" before this provider was given the proper "Claude Code" name).
    private let displayNamesByID: [ProviderID: String]
    /// Plan 03-08 D-07: per-provider `capabilities.hasTokens` snapshot built
    /// from the registry at init. `rollupTotals()` excludes providers whose
    /// entry is `false` (Gemini in v1 — quota-only, no token counts), so the
    /// cross-provider "Today total" never fabricates token figures from a
    /// provider that doesn't report them. Used by Plan 03-07's TotalsHeaderView
    /// to render the "Total excludes quota-only providers" footnote when
    /// `hasAnyQuotaOnlyProvider` is true.
    private let hasTokensByID: [ProviderID: Bool]
    private let clock: any Clock
    private let cache: any CacheStore
    private let thresholds: ThresholdEngine
    private let notifications: any NotificationManager
    /// Plan 02.05 — per-(provider, day) FSM persistence + snooze (NOTIF-04 / NOTIF-05).
    /// Defaulted to `InMemoryNotificationStateStore()` so existing tests stay back-compat.
    private let notificationState: any NotificationStateStorage

    // MARK: - Coalescing state

    /// Tracks the in-flight refresh task so concurrent callers can await it rather than
    /// launching a second fan-out (POLL-03 coalesce).
    private var currentRefresh: Task<Void, Never>?

    // MARK: - Interval state (stub — consumed by PollScheduler / Plan 01.08)

    private var currentInterval: RefreshInterval = .m5

    // MARK: - Plan 02.06 — Per-provider circuit breakers (POLL-05) + POLL-06 terminal skip

    /// Lazy per-provider 5-strike circuit breakers (POLL-05) — separate from any
    /// provider-internal breaker (e.g. Claude's `/api/oauth/usage` 3-strike OAuth-usage
    /// breaker inside `ClaudeJSONLProvider`). Keyed by `ProviderID`; instantiated on
    /// first reference via `breaker(for:)`.
    private var perProviderBreakers: [ProviderID: CircuitBreaker] = [:]

    // MARK: - Init

    /// Creates the store, immediately loading cached provider state so the UI shows
    /// prior data on first open without a "Loading…" flash (UI-07).
    public init(
        registry: [any UsageProvider],
        clock: any Clock,
        cache: any CacheStore,
        thresholds: ThresholdEngine,
        notifications: any NotificationManager,
        notificationState: any NotificationStateStorage = InMemoryNotificationStateStore()
    ) {
        self.registry = registry
        self.clock = clock
        self.cache = cache
        self.thresholds = thresholds
        self.notifications = notifications
        self.notificationState = notificationState

        var names: [ProviderID: String] = [:]
        // Plan 03-08 D-07: capture hasTokens alongside displayName in a single
        // pass over the registry. Both maps are keyed by ProviderID and used
        // by orthogonal subsystems (UI overlay + rollupTotals exclusion).
        var hasTokens: [ProviderID: Bool] = [:]
        for p in registry {
            names[p.id] = p.displayName
            hasTokens[p.id] = p.capabilities.hasTokens
        }
        self.displayNamesByID = names
        self.hasTokensByID = hasTokens

        // UI-07: seed from cache synchronously before any view reads occur.
        var loaded = cache.loadAll()
        // Overlay registry-authoritative displayNames so renamed providers (e.g.
        // "claude" → "Claude Code") update on first launch after the rename
        // without requiring users to wipe their cache.
        for (id, authoritativeName) in names where loaded[id] != nil && loaded[id]?.displayName != authoritativeName {
            if let existing = loaded[id] {
                loaded[id] = ProviderState(
                    id: existing.id,
                    displayName: authoritativeName,
                    placeholderMessage: existing.placeholderMessage,
                    snapshot: existing.snapshot,
                    status: existing.status,
                    lastSuccess: existing.lastSuccess
                )
            }
        }
        self.providers = loaded
        rollupTotals()
    }

    // MARK: - Plan 02.05 — Snooze API (NOTIF-05 + default decision #2)

    /// Records "snoozed for today" for `providerID`, suppressing every threshold band on
    /// that provider until local-midnight rollover. Persists via `NotificationStateStorage`.
    public func snoozeToday(providerID: ProviderID, on now: Date) {
        let day = TodayHelper.formatYYYYMMDD(now)
        let existing = notificationState.record(forProviderID: providerID, day: day)
        let updated = NotificationStateRecord(
            lastBand: existing?.lastBand ?? .normal,
            snoozedUntilDay: day
        )
        notificationState.setRecord(updated, forProviderID: providerID, day: day)
    }

    /// Snoozes ALL currently-seeded providers for today. Used when the user taps Snooze
    /// on a coalesced notification — see `NotificationActionHandler`.
    public func snoozeAllToday(on now: Date) {
        for id in providers.keys {
            snoozeToday(providerID: id, on: now)
        }
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
        placeholderMessage: String? = nil,
        status: ProviderStatus = .unauthenticated
    ) {
        providers[providerID] = ProviderState.placeholder(
            providerID: providerID,
            displayName: displayName,
            placeholderMessage: placeholderMessage,
            status: status
        )
        rollupTotals()
    }

    /// Stub for interval propagation — consumed by `PollScheduler` (Task 2) and
    /// wired in the composition root (Plan 01.08).
    public func setRefreshInterval(_ interval: RefreshInterval) {
        currentInterval = interval
    }

    // MARK: - Plan 02.07 — Stale-data + max quota fraction + menu bar tint (UI-08 / UI-09)

    /// UI-08: returns `true` when the provider's last successful fetch is older than
    /// `2 × currentInterval`, signalling that the data on screen is stale and the row's
    /// `StatusDot` + `RelativeTimestampLabel` should render dimmed.
    ///
    /// Returns `false` when:
    /// - the provider has never produced a `lastSuccess` (no stale baseline yet), OR
    /// - the current refresh interval is `.manual` (`seconds == nil`) — manual refresh has
    ///   no expected cadence and so no automatic "stale" inference is meaningful.
    public func isStale(_ providerID: ProviderID, now: Date) -> Bool {
        guard let state = providers[providerID], let last = state.lastSuccess else {
            return false
        }
        // `.manual` interval = never auto-stale (no expected refresh cadence).
        guard let intervalSec = currentInterval.seconds else {
            return false
        }
        return now.timeIntervalSince(last) > 2.0 * intervalSec
    }

    /// UI-09: the highest quota utilization across all currently-known providers.
    ///
    /// For each provider the contribution is `max(primary quota fraction OR snapshot.quotaWindows
    /// max utilization)`. The cross-provider max of those per-provider values is returned. Returns
    /// `0` when no providers report quota data — semantically "all clear".
    ///
    /// Used by the menu bar icon tint (`menuBarTint`) so the user sees the worst-case quota
    /// across every provider at a glance without opening the popover.
    public var maxQuotaFraction: Double {
        let perProvider: [Double] = providers.values.compactMap { state -> Double? in
            guard let snap = state.snapshot else { return nil }
            let primary = snap.quota?.fraction
            let windowMax = snap.quotaWindows?.compactMap(\.utilization).max()
            let candidates = [primary, windowMax].compactMap { $0 }
            return candidates.max()
        }
        return perProvider.max() ?? 0
    }

    /// UI-09 / Pitfall 9: SwiftUI `Color` for the menu bar icon's `.foregroundStyle(...)`.
    ///
    /// Bands (matches REQUIREMENTS UI-09 / ThresholdState breakpoints):
    /// - `>= 0.95` → `.red`     (critical / exceeded)
    /// - `>= 0.80` → `.yellow`  (warning)
    /// - otherwise → `.green`   (healthy; includes 0 = no quota data)
    ///
    /// Note: SwiftUI `Color` is imported at the file top. `AggregateStore` is already an
    /// `@Observable` view-model concern, so importing SwiftUI is appropriate; the alternative
    /// (exposing a `ThresholdBand` and computing `Color` in the App layer) trades a marginal
    /// architectural purity for an additional indirection in every label binding. Snap
    /// transitions (no animation) are acceptable per Pitfall 9.
    public var menuBarTint: Color {
        let f = maxQuotaFraction
        if f >= 0.95 { return .red }
        if f >= 0.80 { return .yellow }
        return .green
    }

    // MARK: - Private refresh logic

    private func performRefresh(now: Date) async {
        // Plan 02.06 — Pre-compute per-provider gating BEFORE fan-out:
        // 1. POLL-06: skip providers whose lastStatus is `.unauthenticated` (terminal until
        //    composition changes, which typically requires an app restart).
        // 2. POLL-05: skip providers whose 5-strike breaker is currently open.
        var gateDecisions: [(provider: any UsageProvider, allow: Bool, openBreaker: Bool)] = []
        for p in registry {
            // POLL-06 — terminal unauthenticated; do not even consult the breaker.
            if let existing = providers[p.id], case .unauthenticated = existing.status {
                gateDecisions.append((p, false, false))
                continue
            }
            let cb = breaker(for: p.id)
            let allow = await cb.canAttempt(now: now)
            gateDecisions.append((p, allow, !allow))
        }

        await withTaskGroup(of: (ProviderID, Result<UsageSnapshot, Error>).self) { group in
            for decision in gateDecisions {
                let p = decision.provider
                if !decision.allow {
                    if decision.openBreaker {
                        // POLL-05: breaker is open — surface as error result so apply(_:for:)
                        // marks the provider state appropriately.
                        let openErr = ProviderError(kind: .http, message: "circuit-open")
                        group.addTask { (p.id, .failure(openErr)) }
                    }
                    // (POLL-06 terminal-unauth providers contribute no task — preserve last state.)
                    continue
                }
                group.addTask {
                    do {
                        return (p.id, .success(try await p.fetch(now: now)))
                    } catch {
                        return (p.id, .failure(error))
                    }
                }
            }

            for await (id, result) in group {
                switch result {
                case .success:
                    await breaker(for: id).recordSuccess()
                case .failure(let err):
                    let pe = ProviderError.from(err)
                    if pe.kind == .auth || pe.kind == .paymentRequired {
                        // POLL-06: 4xx (non-429) — terminal unauthenticated; do NOT increment
                        // the breaker (config-change required, not endpoint flakiness).
                    } else if pe.message == "circuit-open" {
                        // Already-open breaker — don't double-count.
                    } else {
                        await breaker(for: id).recordFailure(now: now)
                    }
                }
                apply(result, for: id, now: now)
            }
        }

        lastTick = now
        rollupTotals()
        await fireThresholdNotificationsIfNeeded(now: now)
        cache.save(providers)
    }

    /// Lazily creates (or returns the existing) per-provider 5-strike POLL-05 circuit breaker.
    ///
    /// Default thresholds: `threshold = 5`, `cooldown = 300s` — matches RESEARCH §F.2.
    /// The provider-internal Claude OAuth-usage breaker (3-strike, Pitfall 5) is SEPARATE
    /// from this one and lives inside `ClaudeJSONLProvider`.
    private func breaker(for id: ProviderID) -> CircuitBreaker {
        if let existing = perProviderBreakers[id] {
            return existing
        }
        let b = CircuitBreaker()
        perProviderBreakers[id] = b
        return b
    }

    /// Applies a per-provider fetch result, updating the provider's `ProviderState`.
    private func apply(_ result: Result<UsageSnapshot, Error>, for id: ProviderID, now: Date) {
        let authoritativeName = displayNamesByID[id] ?? id.rawValue
        switch result {
        case .success(let snap):
            if let existing = providers[id] {
                providers[id] = existing.applying(snapshot: snap, at: now)
            } else {
                let seed = ProviderState.initial(snapshot: snap, at: now)
                providers[id] = ProviderState(
                    id: seed.id,
                    displayName: authoritativeName,
                    placeholderMessage: seed.placeholderMessage,
                    snapshot: seed.snapshot,
                    status: seed.status,
                    lastSuccess: seed.lastSuccess
                )
            }
        case .failure(let error):
            if let existing = providers[id] {
                providers[id] = existing.applyingError(error, at: now)
            } else {
                let seed = ProviderState.initialError(error, at: now)
                providers[id] = ProviderState(
                    id: id,
                    displayName: authoritativeName,
                    placeholderMessage: seed.placeholderMessage,
                    snapshot: seed.snapshot,
                    status: seed.status,
                    lastSuccess: seed.lastSuccess
                )
            }
        }
    }

    /// Sums `costTodayUSD` and `tokensToday` across all provider snapshots,
    /// excluding providers whose `ProviderCapabilities.hasTokens == false`
    /// (Plan 03-08 D-07 — quota-only providers like Gemini contribute 0
    /// tokens AND 0 USD to the cross-provider total). `nil` tokens within a
    /// snapshot are treated as 0 (OpenRouter does not report token counts).
    ///
    /// The exclusion uses the init-time `hasTokensByID` snapshot rather than
    /// re-reading `UsageProvider.capabilities` (which would require an actor
    /// hop). Providers not present in `hasTokensByID` (cache-restored
    /// placeholders without a registered actor) are included by default —
    /// they'd contribute 0 anyway since their snapshot.tokensToday is nil.
    private func rollupTotals() {
        var totalTokens = 0
        var totalCost: Decimal = 0
        for (id, state) in providers {
            // D-07: skip quota-only providers entirely (no tokens, no cost).
            if hasTokensByID[id] == false { continue }
            guard let snap = state.snapshot else { continue }
            totalTokens += snap.tokensToday ?? 0
            if let cost = snap.costTodayUSD {
                totalCost += cost
            }
        }
        totals = DailyTotals(tokens: totalTokens, costUSD: totalCost)
    }

    /// Plan 03-08 / Plan 03-07: `true` when at least one registered provider
    /// reports `capabilities.hasTokens == false` (i.e. it contributes nothing
    /// to the cross-provider "Today total" per D-07). Plan 03-07's
    /// `TotalsHeaderView` reads this to decide whether to render the
    /// "Total excludes quota-only providers" footnote.
    public var hasAnyQuotaOnlyProvider: Bool {
        hasTokensByID.values.contains(false)
    }

    /// Calls the FSM-aware `ThresholdEngine.decisions(for:now:snoozedUntilDay:lastBands:)`
    /// overload (Plan 02.05) and dispatches results to `NotificationManager`. Persists the
    /// new band per fired decision so the next poll's lastBand comparison is correct.
    private func fireThresholdNotificationsIfNeeded(now: Date) async {
        let snapshots = providers.values.compactMap(\.snapshot)
        let day = TodayHelper.formatYYYYMMDD(now)
        let allRecords = notificationState.allRecordsForToday(day)
        let lastBands: [ProviderID: ThresholdBand] = Dictionary(
            uniqueKeysWithValues: allRecords.map { ($0.0, $0.1.lastBand) }
        )
        let snoozedUntilDay: [ProviderID: String] = Dictionary(
            uniqueKeysWithValues: allRecords.compactMap { pid, rec in
                rec.snoozedUntilDay.map { (pid, $0) }
            }
        )

        let decisions = thresholds.decisions(
            for: snapshots,
            now: now,
            snoozedUntilDay: snoozedUntilDay,
            lastBands: lastBands
        )
        await notifications.schedule(decisions)

        // Persist newly fired band per provider; preserve any existing snooze state.
        for decision in decisions {
            let existing = notificationState.record(forProviderID: decision.providerID, day: day)
            let updated = NotificationStateRecord(
                lastBand: decision.band,
                snoozedUntilDay: existing?.snoozedUntilDay
            )
            notificationState.setRecord(updated, forProviderID: decision.providerID, day: day)
        }
    }
}

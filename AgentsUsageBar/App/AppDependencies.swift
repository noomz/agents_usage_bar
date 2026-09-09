import Foundation
import os

/// Dependency bag returned by `AppDependencies.makeProduction()`.
///
/// Holds the minimum references the `AgentsUsageBarApp` scene needs to inject into SwiftUI:
/// - `store` — the `@Observable @MainActor` source of truth for all provider states.
/// - `scheduler` — the long-lived poll-loop actor driving `store.refresh(now:)`.
/// - `clock` — the `Clock` implementation for `.environment(\.clockService, ...)` injection.
/// - `actionHandler` — Plan 02.05 — `UNUserNotificationCenterDelegate` that routes
///   snooze actions; held strongly for app lifetime so the OS delegate weak-reference
///   does not deallocate the handler.
@MainActor
public final class Dependencies {
    public let store: AggregateStore
    public let scheduler: PollScheduler
    public let clock: any Clock
    public let actionHandler: NotificationActionHandler
    /// Plan 02.06 — `PowerObserver` subscribes to NSWorkspace willSleep/didWake and
    /// drives `scheduler.stop()` / `store.refresh + scheduler.start()` (POLL-04 / POLL-09).
    /// Retained strongly for the app lifetime — without this reference the observer is
    /// deallocated immediately and sleep/wake notifications are dropped (Pitfall 4).
    public let powerObserver: PowerObserver
    /// Plan 05-01 — `WindowActivationObserver` flips activation policy
    /// `.accessory <-> .regular` per Settings/Welcome window lifecycle (D-06 / SHELL-05).
    /// Retained strongly for the app lifetime so NSWindow open/close notifications stay
    /// live; without this reference the observer is deallocated and policy flips silently
    /// drop (Pitfall 4).
    public let windowActivationObserver: WindowActivationObserver
    /// Plan 05-02 — Observable user preferences store backed by UserDefaults.
    /// Injected via `.environment(\.preferences, dependencies.preferences)` in both scenes.
    /// Constructed before `ConfigStore.load(preferences:)` so the UserDefaults overlay is
    /// applied at launch (D-01/D-02).
    public let preferences: UserPreferencesStore
    /// Plan 05-05 — Welcome window host. Retained strongly for app lifetime so the
    /// NSWindow.willCloseNotification observer is not deallocated (Pitfall 4).
    /// `showIfNeeded()` is called from AgentsUsageBarApp `.task` after the scheduler starts;
    /// it is a no-op when `preferences.hasSeenWelcome == true` (D-10).
    public let welcomeWindowController: WelcomeWindowController

    public init(
        store: AggregateStore,
        scheduler: PollScheduler,
        clock: any Clock,
        actionHandler: NotificationActionHandler,
        powerObserver: PowerObserver,
        windowActivationObserver: WindowActivationObserver,
        preferences: UserPreferencesStore,
        welcomeWindowController: WelcomeWindowController
    ) {
        self.store = store
        self.scheduler = scheduler
        self.clock = clock
        self.actionHandler = actionHandler
        self.powerObserver = powerObserver
        self.windowActivationObserver = windowActivationObserver
        self.preferences = preferences
        self.welcomeWindowController = welcomeWindowController
    }
}

/// Composition root — constructs the full production dependency graph.
///
/// B1: `AppDependencies.swift` does NOT instantiate `URLSessionConfiguration` directly.
///     The sole `URLSessionConfiguration` usage (POLL-08: 8s timeout, waitsForConnectivity=false,
///     httpMaximumConnectionsPerHost=6) lives in `URLSessionHTTPClient.init()` (Plan 01.02).
///
/// B6: `ConfigStore` consumed via instance-method `ConfigStore(env: ProcessInfoEnvReader()).load()`.
///     The static form `ConfigStore.load(env:)` does NOT exist.
///
/// B9: On `FileCacheStore()` init failure, falls back to `NoopCacheStore()` (declared in
///     `AgentsUsageBar/Infrastructure/NoopCacheStore.swift`, Plan 01.05).
///     `InMemoryCacheStore` does NOT exist anywhere in the source tree.
///
/// B10: This file does NOT modify `AggregateStore.swift` or `Domain/ProviderState.swift`.
///      `seedPlaceholder(providerID:displayName:status:)` is declared in Plan 01.05's
///      `AggregateStore`; `ProviderState.placeholder(...)` is declared in Plan 01.02's
///      `Domain/ProviderState.swift`. This file only CALLS those existing methods.
@MainActor
public enum AppDependencies {

    /// Builds the full production dependency graph.
    ///
    /// Called once from `AgentsUsageBarApp` via `@State private var dependencies = AppDependencies.makeProduction()`.
    public static func makeProduction() -> Dependencies {
        // 1. Wall clock (shared across all subsystems)
        let clock: any Clock = SystemClock()

        // 2. HTTP clients — TWO tiers per POLL-08 split (Plan 04-03 + CLAUDE.md):
        //    - http:          8s remote tier (OpenRouter / Claude / Codex / Gemini)
        //    - localhostHTTP: 2s localhost tier (Ollama / LM Studio / llama.cpp)
        // B1 invariant preserved: URLSessionConfiguration is OWNED by URLSessionHTTPClient.init()
        // and configured per-tier via the timeoutSeconds parameter.
        let http: any HTTPClient = URLSessionHTTPClient()                       // back-compat default = 8s
        let localhostHTTP: any HTTPClient = URLSessionHTTPClient(timeoutSeconds: 2)

        // 3. Cache store with NoopCacheStore fallback (B9)
        let cache: any CacheStore
        do {
            cache = try FileCacheStore()
        } catch {
            os.Logger(subsystem: "app.agents-usage-bar", category: "composition")
                .error("Cache init failed; using NoopCacheStore: \(error.localizedDescription, privacy: .public)")
            cache = NoopCacheStore()
        }

        // Plan 05-02 — User preferences store (D-01/D-02 UserDefaults overlay).
        // Constructed BEFORE ConfigStore.load(preferences:) so the overlay is applied at launch.
        let preferences = UserPreferencesStore()

        // 4. Config (B6: instance-method API — NOT static ConfigStore.load(env:))
        //    Extended with preferences overlay per D-02 (userDefaults > env > toml > defaults).
        let config = ConfigStore(env: ProcessInfoEnvReader()).load(preferences: preferences)

        // 5–6. Provider registry (shared with `aub` via ProviderRegistryFactory).
        let built = ProviderRegistryFactory.build(
            config: config,
            preferences: preferences,
            http: http,
            localhostHTTP: localhostHTTP,
            cache: cache,
            clock: clock
        )
        let registry = built.providers

        // 7. Threshold engine (warning-at-80% gate per D-11)
        let thresholds = ThresholdEngine(warningFraction: config.threshold)

        // 8a. Notification manager (lazy auth NOTIF-06, coalescing B3+NOTIF-07, clock-injected B8)
        let notifications: any NotificationManager = UNNotificationManager(clock: clock)

        // 8b. Plan 02.05 — Per-(provider, day) FSM persistence + snooze (NOTIF-04 / NOTIF-05).
        //     Prunes records older than 7 days at app launch — bounds the UserDefaults footprint.
        let notificationState = UserDefaultsNotificationStateStore()
        notificationState.pruneOldKeys(olderThan: 7, today: TodayHelper.formatYYYYMMDD(clock.now()))

        // 9. Aggregate store — seeds from cache immediately for cold-launch rendering (UI-07)
        let store = AggregateStore(
            registry: registry,
            clock: clock,
            cache: cache,
            thresholds: thresholds,
            notifications: notifications,
            notificationState: notificationState
        )
        store.updatePaceWarningsEnabled(preferences.paceWarningsEnabled)
        store.updateResetNotificationsEnabled(preferences.resetNotificationsEnabled)

        // 10. Seed placeholder rows when providers are not configured (B10).
        //     Specs come from ProviderRegistryFactory so the GUI and `aub` stay aligned.
        for seed in built.placeholders {
            store.seedPlaceholder(
                providerID: seed.providerID,
                displayName: seed.displayName,
                placeholderMessage: seed.placeholderMessage,
                status: seed.status
            )
        }

        // D-04 cold-start: prefs may disable a provider that cache-load already seeded.
        // Apply the disable set now so the first popover paint never shows hidden rows.
        // (observePreferences only reacts to subsequent changes, not the initial map.)
        for id in ProviderID.allKnown {
            if preferences.providerEnabled[id] == false {
                store.setProviderEnabled(id, enabled: false)
            }
        }

        // Note: Plan 04-04 / 04-05 do NOT skip placeholders for Ollama / LM Studio.
        // Their actors are registered unconditionally when enabled (default true) and the
        // first probe writes a snapshot with .notRunning status if the server is absent.
        // The row STILL appears immediately because seedPlaceholder runs BEFORE the first
        // refresh; once the actor probes and returns a snapshot, apply(_:for:now:) replaces
        // the placeholder state with the live state (Phase 1 STATE #38).

        // 10. Poll scheduler — wired to store; start() called from .task modifier in AgentsUsageBarApp
        let scheduler = PollScheduler(store: store, clock: clock, interval: config.refreshInterval)

        // 11. Plan 02.05 — Notification action handler. Installed as UNUserNotificationCenter
        //     delegate inside AgentsUsageBarApp's `.task { ... }` modifier, AFTER
        //     registerCategories(on:) has run in init() (Pitfall 6).
        let actionHandler = NotificationActionHandler(store: store, clock: clock)

        // 12. Plan 02.06 — PowerObserver wires NSWorkspace willSleep/didWake → scheduler
        //     stop/start (POLL-04 / POLL-09). MUST be constructed AFTER scheduler and held
        //     strongly in Dependencies for the app lifetime (Pitfall 4: observer must be
        //     live before any wake event).
        let powerObserver = PowerObserver(store: store, scheduler: scheduler, clock: clock)

        // 13. Plan 05-01 — WindowActivationObserver wires NSWindow didBecomeKey/willClose
        //     → setActivationPolicy(.regular)/.accessory (D-06 / SHELL-05). MUST be
        //     constructed before the Settings scene opens for the first time and held
        //     strongly in Dependencies for the app lifetime (Pitfall 4 — without strong
        //     retention the observer is deallocated and policy flips silently drop).
        let windowActivationObserver = WindowActivationObserver()

        // 14. Plan 05-05 — WelcomeWindowController (CFG-03/CFG-04/D-09/D-10).
        //     Constructed here; showIfNeeded() called from AgentsUsageBarApp .task after
        //     the scheduler starts. Retained in Dependencies for app lifetime (Pitfall 4 —
        //     NSWindow.willCloseNotification observer must stay live until app exits).
        let welcomeWindowController = WelcomeWindowController(
            preferences: preferences,
            config: config
        )

        return Dependencies(
            store: store,
            scheduler: scheduler,
            clock: clock,
            actionHandler: actionHandler,
            powerObserver: powerObserver,
            windowActivationObserver: windowActivationObserver,
            preferences: preferences,
            welcomeWindowController: welcomeWindowController
        )
    }

    // MARK: - Plan 05-03 — Hot-reload observer (D-04)

    /// Observes `UserPreferencesStore` property changes and propagates them to the running
    /// subsystems (D-04). Runs for the app's lifetime inside a `.task` structured-concurrency
    /// scope; cancelled automatically when the scene tears down.
    ///
    /// Hot-reload paths wired:
    /// - `refreshInterval` → `scheduler.updateInterval(_:)`
    /// - `threshold`       → `store.updateWarningFraction(_:)`
    /// - `providerEnabled` → `store.setProviderEnabled(_:enabled:)` for changed providers
    ///
    /// Theme and open-at-login are wired at the SwiftUI layer (`.preferredColorScheme`) and
    /// in `SettingsGeneralTab.toggleOpenAtLogin` respectively — they do not need actor calls.
    ///
    /// Uses `withObservationTracking(_:onChange:)` — the correct `@Observable` observation API
    /// for non-SwiftUI contexts (macOS 14+, Observation framework). The `onChange` closure fires
    /// once when any tracked property changes; the outer `while` loop immediately re-subscribes.
    @MainActor
    public static func observePreferences(
        _ preferences: UserPreferencesStore,
        scheduler: PollScheduler,
        store: AggregateStore
    ) async {
        var lastInterval = preferences.refreshInterval
        var lastThreshold = preferences.threshold
        var lastPaceWarningsEnabled = preferences.paceWarningsEnabled
        var lastResetNotificationsEnabled = preferences.resetNotificationsEnabled
        var lastProviderEnabled = preferences.providerEnabled

        while !Task.isCancelled {
            // withObservationTracking fires onChange once when any accessed property changes.
            // We use a continuation to bridge the callback-based onChange into async/await.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    // Access the properties we want to observe:
                    _ = preferences.refreshInterval
                    _ = preferences.threshold
                    _ = preferences.paceWarningsEnabled
                    _ = preferences.resetNotificationsEnabled
                    _ = preferences.providerEnabled
                } onChange: {
                    // onChange fires on the thread that made the change.
                    // Resume the continuation to wake the loop.
                    continuation.resume()
                }
            }

            if Task.isCancelled { break }

            // Re-read and react to changes:
            let newInterval = preferences.refreshInterval
            let newThreshold = preferences.threshold
            let newPaceWarningsEnabled = preferences.paceWarningsEnabled
            let newResetNotificationsEnabled = preferences.resetNotificationsEnabled
            let newProviderEnabled = preferences.providerEnabled

            if newInterval != lastInterval {
                lastInterval = newInterval
                await scheduler.updateInterval(newInterval)
            }
            if newThreshold != lastThreshold {
                lastThreshold = newThreshold
                store.updateWarningFraction(newThreshold)
            }
            if newPaceWarningsEnabled != lastPaceWarningsEnabled {
                lastPaceWarningsEnabled = newPaceWarningsEnabled
                store.updatePaceWarningsEnabled(newPaceWarningsEnabled)
            }
            if newResetNotificationsEnabled != lastResetNotificationsEnabled {
                lastResetNotificationsEnabled = newResetNotificationsEnabled
                store.updateResetNotificationsEnabled(newResetNotificationsEnabled)
            }
            if newProviderEnabled != lastProviderEnabled {
                // Find changed providers and propagate to AggregateStore
                for id in ProviderID.allKnown {
                    let wasEnabled = lastProviderEnabled[id] ?? true  // absent = enabled (default)
                    let isEnabled  = newProviderEnabled[id] ?? true
                    if wasEnabled != isEnabled {
                        store.setProviderEnabled(id, enabled: isEnabled)
                    }
                }
                lastProviderEnabled = newProviderEnabled
            }
        }
    }
}

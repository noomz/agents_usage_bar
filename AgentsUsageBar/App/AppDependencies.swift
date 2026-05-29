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

        // 5. Provider registry — OpenRouter only in Phase 1
        var registry: [any UsageProvider] = []
        if let apiKey = config.openrouter.apiKey {
            let endpoint = OpenRouterEndpoint(
                baseURL: config.openrouter.apiURL
            )
            let client = HTTPOpenRouterClient(
                http: http,
                endpoint: endpoint,
                bearer: apiKey,
                httpReferer: config.openrouter.httpReferer,
                xTitle: config.openrouter.xTitle
            )
            let provider = OpenRouterProvider(client: client, cache: cache, clock: clock)
            registry.append(provider)
        }

        // 6. Claude provider (Plan 02.04 — always wired; degrades to local-only when no OAuth creds)
        let credLoader = ClaudeCredentialLoader()
        let oauthClient: (any ClaudeOAuthClientProtocol)?
        if credLoader.loadCredentials() != nil {
            oauthClient = ClaudeOAuthClient(http: http, credentials: credLoader, clock: clock)
        } else {
            oauthClient = nil
        }

        let claudePricing: ClaudeModelPricing
        do {
            claudePricing = try ClaudeModelPricing.loadBundled()
        } catch {
            os.Logger(subsystem: "app.agents-usage-bar", category: "composition")
                .error("Claude pricing load failed: \(error.localizedDescription, privacy: .public)")
            // Degrade to a hardcoded fallback rather than crash (T-02.02-03).
            claudePricing = ClaudeModelPricing(
                schemaVersion: 1,
                lastUpdated: "fallback",
                default: .init(
                    inputPer1M: 3.00,
                    outputPer1M: 15.00,
                    cacheWritePer1M: 3.75,
                    cacheReadPer1M: 0.30
                ),
                models: [:]
            )
        }

        let claudeProvider = ClaudeJSONLProvider(
            reader: TranscriptReader(),
            scanner: TranscriptDirectoryScanner(),
            pricing: claudePricing,
            oauth: oauthClient,
            cache: cache,
            clock: clock
        )
        registry.append(claudeProvider)

        // 6.1. Codex provider (Plan 03-08) — register when config.codex.enabled
        //      AND (~/.codex/sessions exists OR ~/.codex/auth.json exists).
        //      Otherwise the placeholder is seeded later (step 10).
        let codexRegistered: Bool
        if config.codex.enabled {
            let codexCredsLoader = CodexCredentialLoader()
            let codexCreds = codexCredsLoader.loadCredentials()
            let codexSessionsExists = FileManager.default.fileExists(
                atPath: NSHomeDirectory() + "/.codex/sessions"
            )
            if codexCreds != nil || codexSessionsExists {
                let codexPricing: CodexModelPricing?
                do {
                    codexPricing = try CodexModelPricing.loadBundled()
                } catch {
                    os.Logger(subsystem: "app.agents-usage-bar", category: "composition")
                        .error("Codex pricing load failed: \(error.localizedDescription, privacy: .public)")
                    codexPricing = nil  // graceful — cost renders nil
                }
                let codexOAuth: (any CodexOAuthClientProtocol)?
                if codexCreds != nil {
                    codexOAuth = CodexOAuthClient(
                        http: http,
                        credentialLoader: codexCredsLoader,
                        clock: clock
                    )
                } else {
                    codexOAuth = nil
                }
                let codexProvider = CodexJSONLProvider(
                    scannerFactory: { now in CodexRolloutScanner(now: now) },
                    reader: TranscriptReader(),
                    pricing: codexPricing,
                    oauth: codexOAuth,
                    cache: cache,
                    clock: clock
                )
                registry.append(codexProvider)
                codexRegistered = true
            } else {
                codexRegistered = false
            }
        } else {
            codexRegistered = false
        }

        // 6.2. Gemini provider (Plan 03-08) — register when config.gemini.enabled
        //      AND GeminiSettingsGate.isOAuthPersonal() (the user opted into
        //      oauth-personal in ~/.gemini/settings.json) AND credentials present.
        let geminiRegistered: Bool
        if config.gemini.enabled,
           GeminiSettingsGate.isOAuthPersonal(),
           GeminiCredentialLoader().loadCredentials() != nil
        {
            let geminiPublicCreds = GeminiCLIPublicCreds.fromEnvironment(ProcessInfo.processInfo.environment)
            let geminiOAuth = GeminiOAuthClient(
                http: http,
                clock: clock,
                publicCreds: geminiPublicCreds
            )
            let geminiProvider = GeminiOAuthProvider(
                http: http,
                oauth: geminiOAuth,
                clock: clock
            )
            registry.append(geminiProvider)
            geminiRegistered = true
        } else {
            geminiRegistered = false
        }

        // 6.3. Ollama provider (Plan 04-04 — LOCAL-01) — register when config.ollama.enabled.
        //      Well-known port 11434; no presence detection (always probes — first probe
        //      writes .notRunning if server is absent per Phase 3 STATE #82 isolation).
        if config.ollama.enabled {
            let ollamaProvider = OllamaProvider(http: localhostHTTP, clock: clock)
            registry.append(ollamaProvider)
        }

        // 6.4. LM Studio provider (Plan 04-05 — LOCAL-02) — register when config.lmstudio.enabled.
        //      Default port 1234; override via [lmstudio] port = <int> in config.toml.
        if config.lmstudio.enabled {
            let lmstudioProvider = LMStudioProvider(
                http: localhostHTTP,
                clock: clock,
                port: config.lmstudio.port
            )
            registry.append(lmstudioProvider)
        }

        // 6.5. llama.cpp provider (Plan 04-06 — LOCAL-03) — register ONLY when both enabled AND
        //      port is configured (LOCAL-03 no scanning). Unconfigured → seed D-04 placeholder
        //      AFTER the store is constructed (see Step 10 below).
        let llamacppRegistered: Bool
        if config.llamacpp.enabled, let port = config.llamacpp.port {
            let llamacppProvider = LlamaCppProvider(
                http: localhostHTTP,
                clock: clock,
                port: port
            )
            registry.append(llamacppProvider)
            llamacppRegistered = true
        } else {
            llamacppRegistered = false
        }

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

        // 10. Seed placeholder rows when providers are not configured (B10)
        //     seedPlaceholder declared in Plan 01.05's AggregateStore.swift
        //     ProviderState.placeholder declared in Plan 01.02's Domain/ProviderState.swift

        // OpenRouter placeholder: only when api key is absent AND Claude is also absent
        // (if Claude is present the store is non-empty and OpenRouter row is optional).
        // Preserve Phase 1 invariant: when registry has neither provider, seed OpenRouter.
        let hasOpenRouter = config.openrouter.apiKey != nil
        if !hasOpenRouter {
            store.seedPlaceholder(
                providerID: ProviderID.openrouter,
                displayName: "OpenRouter",
                status: .unauthenticated
            )
        }

        // Claude placeholder: when neither OAuth credentials NOR any JSONL root exists (B10).
        let claudeRoots = ClaudeRoots.defaultRoots
        let hasTranscripts = claudeRoots.contains { FileManager.default.fileExists(atPath: $0.path) }
        if oauthClient == nil && !hasTranscripts {
            store.seedPlaceholder(
                providerID: ProviderID.claude,
                displayName: "Claude",
                status: .unauthenticated
            )
        }

        // Plan 03-08 Codex placeholder: when not registered (config disabled
        // OR no rollouts AND no auth.json), seed a row so the popover always
        // shows Codex in the provider list.
        if !codexRegistered {
            store.seedPlaceholder(
                providerID: ProviderID.codex,
                displayName: "Codex",
                status: .unauthenticated
            )
        }

        // Plan 03-08 Gemini placeholder: when not registered (config disabled
        // OR settings gate closed OR no oauth_creds.json), seed a row so the
        // popover always shows Gemini in the provider list.
        if !geminiRegistered {
            store.seedPlaceholder(
                providerID: ProviderID.gemini,
                displayName: "Gemini",
                status: .unauthenticated
            )
        }

        // Plan 04-08 — Ollama placeholder for cold-launch visibility. The actor is also
        // registered (it polls every 5 min); this placeholder ensures the row appears
        // in the popover the moment the user clicks the menu bar icon, BEFORE the first
        // probe returns.
        if config.ollama.enabled {
            store.seedPlaceholder(
                providerID: ProviderID.ollama,
                displayName: "Ollama",
                status: .notRunning
            )
        }

        // Plan 04-08 — LM Studio placeholder (same rationale).
        if config.lmstudio.enabled {
            store.seedPlaceholder(
                providerID: ProviderID.lmstudio,
                displayName: "LM Studio",
                status: .notRunning
            )
        }

        // Plan 04-08 — llama.cpp placeholder when not registered (D-04).
        // Renders a discoverability subtitle so the user knows the feature exists
        // without having to read docs. LOCAL-03 invariant preserved: no port scanning.
        if !llamacppRegistered {
            store.seedPlaceholder(
                providerID: ProviderID.llamacpp,
                displayName: "llama.cpp",
                placeholderMessage: "Set [llamacpp] port in config.toml to enable",
                status: .notRunning
            )
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
        var lastProviderEnabled = preferences.providerEnabled

        while !Task.isCancelled {
            // withObservationTracking fires onChange once when any accessed property changes.
            // We use a continuation to bridge the callback-based onChange into async/await.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    // Access the properties we want to observe:
                    _ = preferences.refreshInterval
                    _ = preferences.threshold
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
            let newProviderEnabled = preferences.providerEnabled

            if newInterval != lastInterval {
                lastInterval = newInterval
                await scheduler.updateInterval(newInterval)
            }
            if newThreshold != lastThreshold {
                lastThreshold = newThreshold
                store.updateWarningFraction(newThreshold)
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

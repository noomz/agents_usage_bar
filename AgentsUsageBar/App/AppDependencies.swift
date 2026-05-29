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

    public init(
        store: AggregateStore,
        scheduler: PollScheduler,
        clock: any Clock,
        actionHandler: NotificationActionHandler
    ) {
        self.store = store
        self.scheduler = scheduler
        self.clock = clock
        self.actionHandler = actionHandler
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

        // 2. HTTP client
        // B1: URLSessionConfiguration is OWNED by URLSessionHTTPClient.init().
        //     POLL-08 (8s timeout, waitsForConnectivity=false, 6 conns/host) lives there.
        //     Do NOT instantiate URLSessionConfiguration here.
        let http: any HTTPClient = URLSessionHTTPClient()

        // 3. Cache store with NoopCacheStore fallback (B9)
        let cache: any CacheStore
        do {
            cache = try FileCacheStore()
        } catch {
            os.Logger(subsystem: "app.agents-usage-bar", category: "composition")
                .error("Cache init failed; using NoopCacheStore: \(error.localizedDescription, privacy: .public)")
            cache = NoopCacheStore()
        }

        // 4. Config (B6: instance-method API — NOT static ConfigStore.load(env:))
        let config = ConfigStore(env: ProcessInfoEnvReader()).load()

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

        // 10. Poll scheduler — wired to store; start() called from .task modifier in AgentsUsageBarApp
        let scheduler = PollScheduler(store: store, clock: clock, interval: config.refreshInterval)

        // 11. Plan 02.05 — Notification action handler. Installed as UNUserNotificationCenter
        //     delegate inside AgentsUsageBarApp's `.task { ... }` modifier, AFTER
        //     registerCategories(on:) has run in init() (Pitfall 6).
        let actionHandler = NotificationActionHandler(store: store, clock: clock)

        return Dependencies(store: store, scheduler: scheduler, clock: clock, actionHandler: actionHandler)
    }
}

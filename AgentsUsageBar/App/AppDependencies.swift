import Foundation
import os

/// Dependency bag returned by `AppDependencies.makeProduction()`.
///
/// Holds the minimum references the `AgentsUsageBarApp` scene needs to inject into SwiftUI:
/// - `store` — the `@Observable @MainActor` source of truth for all provider states.
/// - `scheduler` — the long-lived poll-loop actor driving `store.refresh(now:)`.
/// - `clock` — the `Clock` implementation for `.environment(\.clockService, ...)` injection.
@MainActor
public final class Dependencies {
    public let store: AggregateStore
    public let scheduler: PollScheduler
    public let clock: any Clock

    public init(store: AggregateStore, scheduler: PollScheduler, clock: any Clock) {
        self.store = store
        self.scheduler = scheduler
        self.clock = clock
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

        // 6. Threshold engine (warning-at-80% gate per D-11)
        let thresholds = ThresholdEngine(warningFraction: config.threshold)

        // 7. Notification manager (lazy auth NOTIF-06, coalescing B3+NOTIF-07, clock-injected B8)
        let notifications: any NotificationManager = UNNotificationManager(clock: clock)

        // 8. Aggregate store — seeds from cache immediately for cold-launch rendering (UI-07)
        let store = AggregateStore(
            registry: registry,
            clock: clock,
            cache: cache,
            thresholds: thresholds,
            notifications: notifications
        )

        // 9. Seed "not configured" placeholder row when api key is absent (B10)
        //    seedPlaceholder declared in Plan 01.05's AggregateStore.swift
        //    ProviderState.placeholder declared in Plan 01.02's Domain/ProviderState.swift
        if registry.isEmpty {
            store.seedPlaceholder(
                providerID: ProviderID.openrouter,
                displayName: "OpenRouter",
                status: .unauthenticated
            )
        }

        // 10. Poll scheduler — wired to store; start() called from .task modifier in AgentsUsageBarApp
        let scheduler = PollScheduler(store: store, clock: clock, interval: config.refreshInterval)

        return Dependencies(store: store, scheduler: scheduler, clock: clock)
    }
}

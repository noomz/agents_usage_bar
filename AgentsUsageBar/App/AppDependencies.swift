import Foundation

/// Composition root for the application's dependency graph.
///
/// **Plan 01.01 implementation:** returns a `Container` holding a fresh `AggregateStore`
/// seeded with a single placeholder OpenRouter row.
///
/// Plan 01.05 expands `makeProduction()` to wire:
/// - `URLSessionHTTPClient` (shared URLSession)
/// - `FileCacheStore` (Application Support JSON)
/// - `ConfigStore` (env + config.toml)
/// - `OpenRouterProvider` actor
/// - `ThresholdEngine` + `NotificationManager`
/// - `PollScheduler` (5-minute task loop)
@MainActor
public enum AppDependencies {
    /// The production dependency container.
    public struct Container {
        public let store: AggregateStore
    }

    /// Builds the production container.
    /// Called once from `AgentsUsageBarApp.init()` via `@State`.
    ///
    /// Plan 01.08 replaces this stub with the full wiring (URLSessionHTTPClient,
    /// FileCacheStore, ConfigStore, OpenRouterProvider, PollScheduler).
    public static func makeProduction() -> Container {
        // FileCacheStore() throws only if Application Support directory cannot be created
        // (extremely unlikely on a healthy Mac). Fall through to an in-memory noop on error
        // so the app launches rather than crashing — Plan 01.08 adds proper error reporting.
        let cache: any CacheStore = (try? FileCacheStore()) ?? NoopCacheStore()
        let store = AggregateStore(
            registry: [],
            clock: SystemClock(),
            cache: cache,
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )
        return Container(store: store)
    }
}

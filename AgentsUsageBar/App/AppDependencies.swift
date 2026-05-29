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
    public static func makeProduction() -> Container {
        Container(store: AggregateStore())
    }
}

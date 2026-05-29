import Foundation

/// The operational status of a provider at any given point in time.
///
/// `ProviderStatus` is `Codable` so it can be persisted in the disk cache alongside
/// `ProviderState` and restored on cold launch (D-06, D-07).
public enum ProviderStatus: Sendable, Equatable, Codable {

    /// Last fetch succeeded at `lastSuccess`.
    case ok(lastSuccess: Date)

    /// Last fetch failed but a prior success exists; data is stale.
    case stale(lastSuccess: Date, error: ProviderError)

    /// No API key configured or the key was rejected (HTTP 401/403).
    case unauthenticated

    /// Provider is explicitly disabled by the user in config.
    case disabled

    /// Last fetch failed and no prior success is available.
    case error(ProviderError)
}

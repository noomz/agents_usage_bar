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
    ///
    /// **POLL-06 (Plan 02.06):** This status is TERMINAL until provider config changes —
    /// the AggregateStore skips refreshing any provider in `.unauthenticated` state until
    /// the composition root is rebuilt (typically requires app restart). 4xx responses
    /// other than 429 (e.g. 401/402/403) map to this case via `ProviderError.from(_:)`.
    case unauthenticated

    /// Provider is explicitly disabled by the user in config.
    case disabled

    /// Last fetch failed and no prior success is available.
    case error(ProviderError)
}

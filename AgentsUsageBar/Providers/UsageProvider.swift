import Foundation

/// Contract every provider actor must satisfy.
///
/// All concrete providers must:
/// - Be an `actor` (state isolation; concurrent fetches across providers via withTaskGroup).
/// - Expose nonisolated `id`, `displayName`, `capabilities` so the UI thread reads them without an await hop.
/// - Implement `fetch(now:)` returning a Sendable `UsageSnapshot`. Throw on transient failures; the store applies error per-provider.
/// - Implement `status()` returning the last-recorded ProviderStatus (the actor's internal state).
public protocol UsageProvider: Actor {

    /// Stable provider identifier — used as cache key and notification stable-ID component.
    nonisolated var id: ProviderID { get }

    /// Human-readable name shown in the popover row (e.g. "OpenRouter").
    nonisolated var displayName: String { get }

    /// Static metadata describing what this provider can report (tokens, cost, quota, local).
    nonisolated var capabilities: ProviderCapabilities { get }

    /// Returns the last-recorded operational status without issuing a network call.
    /// Safe to call from MainActor without an await hop (actor isolation on the provider actor).
    func status() -> ProviderStatus

    /// Fetches the latest usage data as of `now` and returns an immutable snapshot.
    ///
    /// - Parameter now: The wall-clock time to use for baseline-delta and rollover logic.
    /// - Throws: Any error from the underlying transport or decoder; callers (AggregateStore)
    ///   catch per-provider and record `ProviderStatus.error(_)` without crashing the app.
    func fetch(now: Date) async throws -> UsageSnapshot
}

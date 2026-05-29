import Foundation

/// Per-provider UI state exposed by `AggregateStore` to SwiftUI views.
///
/// **Plan 01.02 extension** — adds `snapshot`, `status`, `lastSuccess` to the
/// Plan 01.01 minimal struct. All new fields have defaults in `init` so the
/// Plan 01.01 smoke test (`ProviderState(id:displayName:placeholderMessage:)`)
/// continues to compile and pass without modification.
///
/// **Ownership:** `ProviderState` is OWNED by this file in `AgentsUsageBar/Domain/`.
/// Plans 01.05 and downstream IMPORT this type — no duplicate declaration in
/// `Aggregation/` or elsewhere. (B10 note.)
///
/// `ProviderState` is `Codable` so it can be persisted in `FileCacheStore` (D-06)
/// and restored on cold launch (UI-07: no "Loading…" flash on reopen).
public struct ProviderState: Sendable, Equatable, Codable {

    // MARK: - Fields

    /// Stable typed identifier for the provider.
    public let id: ProviderID

    /// Human-readable name shown in popover rows (e.g. `"OpenRouter"`).
    public let displayName: String

    /// Shown in the placeholder row until Plan 01.03 wires key resolution.
    /// `nil` means the provider is configured and a real value should be visible.
    public let placeholderMessage: String?

    /// Latest usage data from the provider, or `nil` on cold launch / unauthenticated.
    public let snapshot: UsageSnapshot?

    /// Current operational status of the provider.
    public let status: ProviderStatus

    /// Timestamp of the most recent successful fetch, or `nil` if none yet.
    public let lastSuccess: Date?

    // MARK: - Initializer

    public init(
        id: ProviderID,
        displayName: String,
        placeholderMessage: String? = nil,
        snapshot: UsageSnapshot? = nil,
        status: ProviderStatus = .unauthenticated,
        lastSuccess: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.placeholderMessage = placeholderMessage
        self.snapshot = snapshot
        self.status = status
        self.lastSuccess = lastSuccess
    }

    // MARK: - B10: Placeholder factory

    /// Returns a `ProviderState` with `snapshot == nil` and the given `status`.
    ///
    /// B10: Consumed by `AggregateStore.seedPlaceholder(...)` (Plan 01.05) and
    /// `AppDependencies.makeProduction` (Plan 01.08) when no API key is configured.
    public static func placeholder(
        providerID: ProviderID,
        displayName: String,
        placeholderMessage: String? = nil,
        status: ProviderStatus = .unauthenticated
    ) -> ProviderState {
        ProviderState(
            id: providerID,
            displayName: displayName,
            placeholderMessage: placeholderMessage,
            snapshot: nil,
            status: status,
            lastSuccess: nil
        )
    }

    // MARK: - Mutating helpers (value-type update pattern)

    /// Returns a copy updated with a successful fetch result.
    public func applying(snapshot: UsageSnapshot, at now: Date) -> ProviderState {
        ProviderState(
            id: id,
            displayName: displayName,
            placeholderMessage: placeholderMessage,
            snapshot: snapshot,
            status: .ok(lastSuccess: now),
            lastSuccess: now
        )
    }

    /// Returns a copy updated with a fetch error, preserving the previous snapshot (stale).
    public func applyingError(_ error: Error, at now: Date) -> ProviderState {
        let providerError = ProviderError.from(error)
        let newStatus: ProviderStatus
        if let ls = lastSuccess {
            newStatus = .stale(lastSuccess: ls, error: providerError)
        } else {
            newStatus = .error(providerError)
        }
        return ProviderState(
            id: id,
            displayName: displayName,
            placeholderMessage: placeholderMessage,
            snapshot: snapshot,        // keep prior snapshot (stale display)
            status: newStatus,
            lastSuccess: lastSuccess   // retain prior success timestamp
        )
    }

    /// Creates an initial `ProviderState` from the first successful fetch.
    public static func initial(snapshot: UsageSnapshot, at now: Date) -> ProviderState {
        ProviderState(
            id: snapshot.providerID,
            displayName: snapshot.providerID.rawValue,
            placeholderMessage: nil,
            snapshot: snapshot,
            status: .ok(lastSuccess: now),
            lastSuccess: now
        )
    }

    /// Creates an initial `ProviderState` from the first fetch failure.
    public static func initialError(_ error: Error, at now: Date) -> ProviderState {
        let providerError = ProviderError.from(error)
        return ProviderState(
            id: ProviderID(rawValue: "unknown"),
            displayName: "Unknown",
            placeholderMessage: nil,
            snapshot: nil,
            status: .error(providerError),
            lastSuccess: nil
        )
    }
}

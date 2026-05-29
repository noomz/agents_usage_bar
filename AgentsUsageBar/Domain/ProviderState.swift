/// Per-provider UI state exposed by `AggregateStore` to SwiftUI views.
///
/// **Plan 01.01 minimal version** — this struct carries only the fields required
/// to compile and render the Walking Skeleton popover row.
///
/// Plan 01.02 extends this with:
/// - `snapshot: UsageSnapshot?`   — real tokens/cost/quota data from the provider actor
/// - `status: ProviderStatus`      — ok | stale | error | disabled | unauthenticated
/// - `lastSuccess: Date?`          — timestamp of the last successful fetch
///
/// These fields are intentionally absent in Plan 01.01 so the scene compiles
/// without the full Domain layer that Plan 01.02 ships.
public struct ProviderState: Sendable, Equatable {
    public let id: ProviderID
    public let displayName: String

    /// Shown in the placeholder row until Plan 01.03 wires key resolution.
    /// `nil` means the provider is configured and a real value should be visible.
    public let placeholderMessage: String?

    public init(
        id: ProviderID,
        displayName: String,
        placeholderMessage: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.placeholderMessage = placeholderMessage
    }
}

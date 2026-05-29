import Observation
import Foundation

/// Phase 1 Walking Skeleton stub.
///
/// Seeds a single placeholder OpenRouter row so the SwiftUI popover compiles and renders.
/// Plan 01.05 replaces this with the real implementation:
/// refresh(now:), withTaskGroup fan-out, cache load on init, coalescing,
/// PollScheduler integration, and ThresholdEngine dispatch.
@Observable
@MainActor
public final class AggregateStore {
    /// Per-provider UI state keyed by `ProviderID`.
    /// Plan 01.02 adds `snapshot`, `status`, and `lastSuccess` to `ProviderState`.
    /// Plan 01.05 mutates this map on every poll tick.
    public private(set) var providers: [ProviderID: ProviderState] = [:]

    public init() {
        // Seed one placeholder row so the popover has content from the moment
        // the user first clicks the menu bar icon (no "Loading…" flash).
        // Plan 01.03 replaces "Not configured" with the real config-resolved status.
        providers[.openrouter] = ProviderState(
            id: .openrouter,
            displayName: "OpenRouter",
            placeholderMessage: "Not configured"
        )
    }
}

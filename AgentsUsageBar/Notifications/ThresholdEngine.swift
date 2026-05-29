// STUB — overwritten by Plan 01.07
import Foundation

/// Stub threshold engine — returns empty decisions.
///
/// Plan 01.07 replaces this file entirely with the real implementation
/// that computes notification decisions based on usage percentages.
///
/// This stub exists so `AggregateStore.swift` compiles before Plan 01.07 lands (B2).
public struct ThresholdEngine: Sendable {
    public init() {}

    /// Returns the list of notification decisions for the given snapshots.
    /// Stub implementation always returns an empty array.
    public func decisions(
        for snapshots: [UsageSnapshot],
        now: Date,
        snoozedUntil: [ProviderID: Date]
    ) -> [NotificationDecision] {
        []
    }
}

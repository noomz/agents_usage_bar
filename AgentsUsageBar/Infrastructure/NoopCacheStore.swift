import Foundation

/// A no-op `CacheStore` used as a fallback when `FileCacheStore` cannot be initialized.
///
/// All reads return empty results; all writes are silently discarded.
/// This ensures the app launches even when the Application Support directory is unavailable,
/// at the cost of losing cache persistence for that session.
///
/// Plan 01.08 adds proper error reporting for this edge case.
public struct NoopCacheStore: CacheStore {
    public init() {}

    public func loadAll() -> [ProviderID: ProviderState] { [:] }
    public func save(_ providers: [ProviderID: ProviderState]) {}
    public func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? { nil }
    public func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {}
}

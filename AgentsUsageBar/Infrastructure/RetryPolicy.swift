import Foundation

/// Decorrelated jitter backoff policy.
///
/// Algorithm: AWS Architecture Blog "Exponential Backoff and Jitter" — decorrelated jitter.
/// Formula: `sleep = min(maxDelay, random(baseDelay, lastSleep * 3))`
///
/// The decorrelated formula avoids synchronized retries across many clients by randomising
/// each client's delay independently of the previous attempt's jitter. Unlike pure random
/// exponential backoff, the upper bound grows with the last actual delay, so bursty retries
/// naturally space themselves out over time.
///
/// RESEARCH §F.1 — RetryPolicy value type.
///
/// Note: `RetryPolicy` is INTENTIONALLY NOT an actor — it is a pure value type whose only
/// state-mutating call during `nextDelay(after:)` is `TimeInterval.random(in:)`, which is
/// statistically independent per call. Any caller that wants to track `lastDelay` across
/// retry attempts does so externally (the policy itself is stateless).
public struct RetryPolicy: Sendable, Equatable {

    /// Minimum delay (seconds) returned for any retry. Default: 1.
    public let baseDelay: TimeInterval

    /// Maximum delay (seconds) returned for any retry. Default: 60.
    public let maxDelay: TimeInterval

    /// Maximum number of retry attempts before giving up. Default: 5.
    public let maxAttempts: Int

    public init(
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 60,
        maxAttempts: Int = 5
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    /// Returns the next retry delay given the previous delay (or `0` for the first attempt).
    ///
    /// Decorrelated jitter formula:
    /// ```
    /// upper = min(maxDelay, lastDelay * 3)
    /// if upper <= baseDelay { return baseDelay }
    /// return random(baseDelay, upper)
    /// ```
    ///
    /// When `lastDelay == 0` (first retry): `upper = min(maxDelay, 0) = 0 < baseDelay`,
    /// so `baseDelay` is returned. This is the correct behavior per AWS guidance: the first
    /// retry always uses `baseDelay`.
    public func nextDelay(after lastDelay: TimeInterval) -> TimeInterval {
        let upper = min(maxDelay, lastDelay * 3)
        let lower = baseDelay
        guard upper > lower else { return lower }
        return TimeInterval.random(in: lower...upper)
    }

    /// Shared default instance using recommended production settings
    /// (baseDelay: 1s, maxDelay: 60s, maxAttempts: 5).
    public static let `default`: RetryPolicy = RetryPolicy()
}

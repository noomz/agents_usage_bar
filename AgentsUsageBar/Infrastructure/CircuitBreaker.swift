import Foundation

// MARK: - CircuitBreakerState

/// The three states of the circuit breaker state machine.
///
/// POLL-05: protects provider fetches from cascading 5xx failures (general breaker, threshold 5).
/// Pitfall 5: the OAuth-usage endpoint is wrapped by a separate 3-strike breaker for persistent 429s.
public enum CircuitBreakerState: Sendable, Equatable {
    /// Normal operation — all attempts are allowed.
    case closed
    /// Breaker tripped — attempts are blocked until `until` has passed.
    case open(until: Date)
    /// Cooldown elapsed — one trial attempt is allowed; success → `.closed`; failure → re-trip.
    case halfOpen
}

// MARK: - CircuitBreaker

/// Actor-isolated per-provider circuit breaker.
///
/// **State machine** (RESEARCH §F.2):
/// - `.closed` → consecutive failures reach `threshold` → `.open(until: now + cooldown)`
/// - `.open(until:)` → `canAttempt(now:)` called after cooldown → transitions to `.halfOpen`
/// - `.halfOpen` → `recordSuccess()` → `.closed`; `recordFailure(now:)` → re-trip to `.open`
///
/// **Default thresholds:**
/// - General provider 5xx breaker: `threshold = 5`, `cooldown = 300s` (5 min). (POLL-05)
/// - OAuth-usage 429 breaker (inside `ClaudeJSONLProvider`): `threshold = 3`, `cooldown = 300s`. (Pitfall 5)
public actor CircuitBreaker {

    // MARK: - Private state

    private let threshold: Int
    private let cooldown: TimeInterval
    private var failureCount: Int = 0
    private var state: CircuitBreakerState = .closed

    // MARK: - Init

    /// Creates a circuit breaker.
    ///
    /// - Parameters:
    ///   - threshold: Number of consecutive failures required to trip the breaker. Default: 5.
    ///   - cooldown: Seconds to stay in `.open` before transitioning to `.halfOpen`. Default: 300.
    public init(threshold: Int = 5, cooldown: TimeInterval = 300) {
        self.threshold = threshold
        self.cooldown = cooldown
    }

    // MARK: - Public API

    /// Returns `true` if an attempt should proceed.
    ///
    /// - `.closed`: always `true`.
    /// - `.open(until:)`: `false` until `now >= until`, then transitions to `.halfOpen` and returns `true`.
    /// - `.halfOpen`: `true` (one trial attempt).
    public func canAttempt(now: Date) -> Bool {
        switch state {
        case .closed:
            return true
        case .open(let until):
            if now >= until {
                state = .halfOpen
                return true
            } else {
                return false
            }
        case .halfOpen:
            return true
        }
    }

    /// Records a successful attempt.
    ///
    /// Resets `failureCount` to 0 and transitions to `.closed` regardless of prior state.
    public func recordSuccess() {
        failureCount = 0
        state = .closed
    }

    /// Records a failed attempt.
    ///
    /// Increments `failureCount`; when `failureCount >= threshold`, trips to `.open(until: now + cooldown)`.
    /// In `.halfOpen`, a failure re-trips the breaker with a fresh cooldown window.
    public func recordFailure(now: Date) {
        failureCount += 1
        if failureCount >= threshold {
            state = .open(until: now.addingTimeInterval(cooldown))
        }
    }

    /// Returns the current breaker state — used for testability and status surface.
    public func currentState() -> CircuitBreakerState {
        state
    }
}

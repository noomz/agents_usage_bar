import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("RetryPolicyTests")
struct RetryPolicyTests {

    // MARK: - Test 1: lastDelay == 0 returns baseDelay

    @Test("defaultPolicy_nextDelay_zero_returnsBaseDelay")
    func defaultPolicy_nextDelay_zero_returnsBaseDelay() {
        let policy = RetryPolicy()
        let delay = policy.nextDelay(after: 0)
        #expect(delay == 1.0)
    }

    // MARK: - Test 2: progressive bounds for typical delays

    @Test("nextDelay_doublingProgression_isWithinUpperBound")
    func nextDelay_doublingProgression_isWithinUpperBound() {
        let policy = RetryPolicy()

        // lastDelay = 1 → upper = min(60, 3) = 3 → result ∈ [1, 3]
        for _ in 0..<100 {
            let d = policy.nextDelay(after: 1)
            #expect(d >= 1.0 && d <= 3.0, "lastDelay=1: expected [1,3], got \(d)")
        }

        // lastDelay = 5 → upper = min(60, 15) = 15 → result ∈ [1, 15]
        for _ in 0..<100 {
            let d = policy.nextDelay(after: 5)
            #expect(d >= 1.0 && d <= 15.0, "lastDelay=5: expected [1,15], got \(d)")
        }

        // lastDelay = 30 → upper = min(60, 90) = 60 → result ∈ [1, 60]
        for _ in 0..<100 {
            let d = policy.nextDelay(after: 30)
            #expect(d >= 1.0 && d <= 60.0, "lastDelay=30: expected [1,60], got \(d)")
        }
    }

    // MARK: - Test 3: result is capped at maxDelay

    @Test("nextDelay_capsAtMaxDelay")
    func nextDelay_capsAtMaxDelay() {
        let policy = RetryPolicy(maxDelay: 10)
        // lastDelay = 100 → upper = min(10, 300) = 10 → result ∈ [1, 10]
        for _ in 0..<100 {
            let d = policy.nextDelay(after: 100)
            #expect(d >= 1.0 && d <= 10.0, "expected [1,10] with maxDelay=10, got \(d)")
        }
    }

    // MARK: - Test 4: custom baseDelay is honoured at lastDelay == 0

    @Test("nextDelay_baseDelayPreserved")
    func nextDelay_baseDelayPreserved() {
        let policy = RetryPolicy(baseDelay: 2.5)
        let delay = policy.nextDelay(after: 0)
        #expect(delay == 2.5)
    }

    // MARK: - Test 5: Equatable conformance

    @Test("policy_isEquatable")
    func policy_isEquatable() {
        let a = RetryPolicy(baseDelay: 1, maxDelay: 60, maxAttempts: 5)
        let b = RetryPolicy(baseDelay: 1, maxDelay: 60, maxAttempts: 5)
        let c = RetryPolicy(baseDelay: 2, maxDelay: 60, maxAttempts: 5)
        #expect(a == b)
        #expect(a != c)
    }
}

import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("CircuitBreakerTests")
struct CircuitBreakerTests {

    // Pinned base time for all tests
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Test 1: fresh breaker is closed and allows attempts

    @Test("freshBreaker_isClosed_canAttempt")
    func freshBreaker_isClosed_canAttempt() async {
        let cb = CircuitBreaker()
        let can = await cb.canAttempt(now: now)
        let state = await cb.currentState()
        #expect(can == true)
        #expect(state == .closed)
    }

    // MARK: - Test 2: success on closed breaker keeps it closed

    @Test("recordSuccess_keepsClosed")
    func recordSuccess_keepsClosed() async {
        let cb = CircuitBreaker()
        await cb.recordSuccess()
        let can = await cb.canAttempt(now: now)
        let state = await cb.currentState()
        #expect(can == true)
        #expect(state == .closed)
    }

    // MARK: - Test 3: single failure below threshold stays closed

    @Test("singleFailure_belowThreshold_remainsClosed")
    func singleFailure_belowThreshold_remainsClosed() async {
        let cb = CircuitBreaker()
        await cb.recordFailure(now: now)
        let can = await cb.canAttempt(now: now)
        let state = await cb.currentState()
        #expect(can == true)
        #expect(state == .closed)
    }

    // MARK: - Test 4: four failures below default threshold (5) still closed

    @Test("fourFailures_belowDefaultThreshold5_remainsClosed")
    func fourFailures_belowDefaultThreshold5_remainsClosed() async {
        let cb = CircuitBreaker()
        for _ in 0..<4 {
            await cb.recordFailure(now: now)
        }
        let state = await cb.currentState()
        let can = await cb.canAttempt(now: now)
        #expect(state == .closed)
        #expect(can == true)
    }

    // MARK: - Test 5: fifth failure trips the breaker to open

    @Test("fifthFailure_atDefaultThreshold5_trips_open")
    func fifthFailure_atDefaultThreshold5_trips_open() async {
        let cb = CircuitBreaker()
        for _ in 0..<5 {
            await cb.recordFailure(now: now)
        }
        let state = await cb.currentState()
        #expect(state == .open(until: now.addingTimeInterval(300)))
    }

    // MARK: - Test 6: open breaker blocks attempts before cooldown

    @Test("openState_canAttempt_returnsFalse_beforeCooldown")
    func openState_canAttempt_returnsFalse_beforeCooldown() async {
        let cb = CircuitBreaker()
        for _ in 0..<5 {
            await cb.recordFailure(now: now)
        }
        let can = await cb.canAttempt(now: now.addingTimeInterval(100))
        #expect(can == false)
    }

    // MARK: - Test 7: open breaker transitions to halfOpen after cooldown

    @Test("openState_transitions_to_halfOpen_after_cooldown")
    func openState_transitions_to_halfOpen_after_cooldown() async {
        let cb = CircuitBreaker()
        for _ in 0..<5 {
            await cb.recordFailure(now: now)
        }
        let can = await cb.canAttempt(now: now.addingTimeInterval(301))
        let state = await cb.currentState()
        #expect(can == true)
        #expect(state == .halfOpen)
    }

    // MARK: - Test 8: halfOpen + success → closed

    @Test("halfOpen_recordSuccess_returns_to_closed")
    func halfOpen_recordSuccess_returns_to_closed() async {
        let cb = CircuitBreaker()
        // Trip open
        for _ in 0..<5 {
            await cb.recordFailure(now: now)
        }
        // Advance past cooldown → halfOpen
        _ = await cb.canAttempt(now: now.addingTimeInterval(301))
        // Record success
        await cb.recordSuccess()
        let state = await cb.currentState()
        let can = await cb.canAttempt(now: now.addingTimeInterval(301))
        #expect(state == .closed)
        #expect(can == true)
    }

    // MARK: - Test 9: halfOpen + failure → re-trips to open

    @Test("halfOpen_recordFailure_re_trips_to_open_with_new_cooldown")
    func halfOpen_recordFailure_re_trips_to_open_with_new_cooldown() async {
        let cb = CircuitBreaker()
        // Trip open
        for _ in 0..<5 {
            await cb.recordFailure(now: now)
        }
        // Advance past cooldown → halfOpen
        _ = await cb.canAttempt(now: now.addingTimeInterval(301))
        // Fail the trial
        let now2 = now.addingTimeInterval(400)
        await cb.recordFailure(now: now2)
        let state = await cb.currentState()
        // After halfOpen, failureCount was 5 before transition. After transition to halfOpen
        // the count is still 5 but state is halfOpen. recordFailure increments to 6 ≥ 5 → trips.
        #expect(state == .open(until: now2.addingTimeInterval(300)))
    }

    // MARK: - Test 10: custom threshold 3 for OAuth-usage breaker

    @Test("customThreshold_3_for_OAuthUsage_breaker")
    func customThreshold_3_for_OAuthUsage_breaker() async {
        let cb = CircuitBreaker(threshold: 3, cooldown: 300)

        // 2 failures → still closed
        await cb.recordFailure(now: now)
        await cb.recordFailure(now: now)
        let stateAfter2 = await cb.currentState()
        #expect(stateAfter2 == .closed)

        // 3rd failure → open
        await cb.recordFailure(now: now)
        let stateAfter3 = await cb.currentState()
        #expect(stateAfter3 == .open(until: now.addingTimeInterval(300)))
    }

    // MARK: - Test 11: custom cooldown 60s

    @Test("customCooldown_60s")
    func customCooldown_60s() async {
        let cb = CircuitBreaker(threshold: 3, cooldown: 60)
        for _ in 0..<3 {
            await cb.recordFailure(now: now)
        }
        // 30s after trip → still open
        let canAt30 = await cb.canAttempt(now: now.addingTimeInterval(30))
        #expect(canAt30 == false)

        // 61s after trip → halfOpen, allows attempt
        let canAt61 = await cb.canAttempt(now: now.addingTimeInterval(61))
        #expect(canAt61 == true)
        let state = await cb.currentState()
        #expect(state == .halfOpen)
    }

    // MARK: - Test 12: success after partial failures resets count

    @Test("recordSuccess_after_partial_failures_resets_count")
    func recordSuccess_after_partial_failures_resets_count() async {
        let cb = CircuitBreaker() // threshold = 5
        // 3 failures (below threshold)
        for _ in 0..<3 {
            await cb.recordFailure(now: now)
        }
        // Success resets count
        await cb.recordSuccess()

        // Now 4 more failures → should still be closed (count was reset to 0, now at 4)
        for _ in 0..<4 {
            await cb.recordFailure(now: now)
        }
        let state = await cb.currentState()
        #expect(state == .closed)
    }
}

import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("ResetCountdown remaining-time units")
struct ResetCountdownTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("already due → Resets now")
    func alreadyDue() {
        #expect(ResetCountdown.phrase(until: now, now: now) == "Resets now")
        #expect(ResetCountdown.phrase(until: now.addingTimeInterval(-1), now: now) == "Resets now")
    }

    @Test("<1m")
    func underOneMinute() {
        #expect(phrase(seconds: 1) == "Resets <1m")
        #expect(phrase(seconds: 59) == "Resets <1m")
    }

    @Test("<1h is minutes only")
    func minutesOnly() {
        #expect(phrase(seconds: 60) == "Resets 1m")
        #expect(phrase(seconds: 5 * 60) == "Resets 5m")
        #expect(phrase(seconds: 59 * 60) == "Resets 59m")
    }

    @Test("<24h is hours + minutes")
    func hoursAndMinutes() {
        #expect(phrase(seconds: 3600) == "Resets 1h")
        #expect(phrase(seconds: 3 * 3600 + 12 * 60) == "Resets 3h 12m")
        #expect(phrase(seconds: 23 * 3600 + 59 * 60) == "Resets 23h 59m")
    }

    @Test("≥24h is days + hours")
    func daysAndHours() {
        #expect(phrase(seconds: 24 * 3600) == "Resets 1d")
        #expect(phrase(seconds: 25 * 3600 + 10 * 60) == "Resets 1d 1h")
        #expect(phrase(seconds: 7 * 86400) == "Resets 7d")
        #expect(phrase(seconds: 7 * 86400 + 3 * 3600) == "Resets 7d 3h")
        #expect(phrase(seconds: 14 * 86400 + 5 * 3600) == "Resets 14d 5h")
    }

    @Test("CLI wrapper matches domain helper")
    func cliWrapper() {
        let until = now.addingTimeInterval(7 * 86400 + 3 * 3600)
        #expect(UsageTextRenderer.resetsPhrase(until: until, now: now) == "Resets 7d 3h")
    }

    private func phrase(seconds: TimeInterval) -> String {
        ResetCountdown.phrase(until: now.addingTimeInterval(seconds), now: now)
    }
}

import Testing
@testable import AgentsUsageBar

@Suite("SecretTests")
struct SecretTests {

    @Test("description returns <redacted>")
    func secretDescriptionRedacts() {
        #expect(String(describing: Secret("sk-or-real-key")) == "<redacted>")
    }

    @Test("debugDescription contains <redacted>")
    func secretDebugDescriptionRedacts() {
        #expect(String(reflecting: Secret("sk-or-real-key")).contains("<redacted>"))
    }

    @Test("string interpolation yields <redacted>")
    func secretInterpolationViaLoggerDescriptionPath() {
        let s = "\(Secret("sk-or-real-key"))"
        #expect(s == "<redacted>")
    }

    @Test("revealForRequest returns original value")
    func secretRevealReturnsOriginal() {
        #expect(Secret("sk-or-X").revealForRequest() == "sk-or-X")
    }
}

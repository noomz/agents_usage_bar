import Testing
@testable import AgentsUsageBar

@Suite("SecretTests")
struct SecretTests {

    @Test("description returns <redacted>")
    func secretDescriptionRedacts() {
        // Use a non-key-prefix test value — Secret wraps any string; the redaction behavior
        // does not depend on the credential format. Real key prefixes must not appear in
        // test source per SEC-04 CI grep contract.
        #expect(String(describing: Secret("test-bearer-token")) == "<redacted>")
    }

    @Test("debugDescription contains <redacted>")
    func secretDebugDescriptionRedacts() {
        #expect(String(reflecting: Secret("test-bearer-token")).contains("<redacted>"))
    }

    @Test("string interpolation yields <redacted>")
    func secretInterpolationViaLoggerDescriptionPath() {
        let s = "\(Secret("test-bearer-token"))"
        #expect(s == "<redacted>")
    }

    @Test("revealForRequest returns original value")
    func secretRevealReturnsOriginal() {
        // Any string value works; the reveal contract is format-agnostic.
        #expect(Secret("test-api-key").revealForRequest() == "test-api-key")
    }
}

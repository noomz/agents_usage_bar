import Testing
import Foundation
@testable import AgentsUsageBar

/// Plan 04-01 / T-04-01-04 — verifies `ProviderStatus.classifyLocalhost(error:lastSuccess:)`
/// maps connection-refused `URLError.Code` values to `.notRunning` and all other errors
/// to `.error` or `.stale` as appropriate (LOCAL-05 / RESEARCH §3.1).
@Suite("ProviderErrorLocalhostClassifierTests")
struct ProviderErrorLocalhostClassifierTests {

    // MARK: - Connection-refused codes → .notRunning

    @Test("cannotConnectToHost maps to .notRunning")
    func cannotConnectToHost_mapsToNotRunning() {
        let result = ProviderStatus.classifyLocalhost(
            error: URLError(.cannotConnectToHost),
            lastSuccess: nil
        )
        #expect(result == .notRunning)
    }

    @Test("cannotFindHost maps to .notRunning")
    func cannotFindHost_mapsToNotRunning() {
        let result = ProviderStatus.classifyLocalhost(
            error: URLError(.cannotFindHost),
            lastSuccess: nil
        )
        #expect(result == .notRunning)
    }

    @Test("networkConnectionLost maps to .notRunning")
    func networkConnectionLost_mapsToNotRunning() {
        let result = ProviderStatus.classifyLocalhost(
            error: URLError(.networkConnectionLost),
            lastSuccess: nil
        )
        #expect(result == .notRunning)
    }

    @Test("timedOut maps to .notRunning")
    func timedOut_mapsToNotRunning() {
        let result = ProviderStatus.classifyLocalhost(
            error: URLError(.timedOut),
            lastSuccess: nil
        )
        #expect(result == .notRunning)
    }

    // MARK: - notRunning wins over stale (success-class signal)

    @Test("cannotConnectToHost with non-nil lastSuccess still maps to .notRunning (not .stale)")
    func urlError_withLastSuccess_mapsToNotRunning() {
        let lastSuccess = Date().addingTimeInterval(-300)
        let result = ProviderStatus.classifyLocalhost(
            error: URLError(.cannotConnectToHost),
            lastSuccess: lastSuccess
        )
        // .notRunning is the success-class signal that wins over the stale fallback
        #expect(result == .notRunning)
    }

    // MARK: - Other errors → .error (no prior success)

    @Test("notConnectedToInternet maps to .error (NOT .notRunning)")
    func notConnectedToInternet_mapsToError() {
        let result = ProviderStatus.classifyLocalhost(
            error: URLError(.notConnectedToInternet),
            lastSuccess: nil
        )
        if case .error = result {
            // correct
        } else {
            Issue.record("Expected .error for notConnectedToInternet, got \(result)")
        }
    }

    @Test("HTTP 500 maps to .error (server is up but unhealthy — NOT .notRunning)")
    func http500_mapsToError() {
        let result = ProviderStatus.classifyLocalhost(
            error: HTTPError(status: 500),
            lastSuccess: nil
        )
        if case .error(let pe) = result {
            #expect(pe.kind == .http)
        } else {
            Issue.record("Expected .error(.http) for HTTP 500, got \(result)")
        }
    }

    @Test("DecodingError maps to .error(.decode)")
    func decodingError_mapsToError() {
        let decodingError = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "bad data")
        )
        let result = ProviderStatus.classifyLocalhost(
            error: decodingError,
            lastSuccess: nil
        )
        if case .error(let pe) = result {
            #expect(pe.kind == .decode)
        } else {
            Issue.record("Expected .error(.decode) for DecodingError, got \(result)")
        }
    }

    // MARK: - Stale path (non-connection-refused error + prior success)

    @Test("non-connection-refused URLError with lastSuccess maps to .stale")
    func nonRefusedUrlError_withLastSuccess_mapsToStale() {
        let lastSuccess = Date().addingTimeInterval(-120)
        let result = ProviderStatus.classifyLocalhost(
            error: URLError(.notConnectedToInternet),
            lastSuccess: lastSuccess
        )
        if case .stale = result {
            // correct
        } else {
            Issue.record("Expected .stale for non-refused URLError with lastSuccess, got \(result)")
        }
    }
}

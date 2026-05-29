import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - URLSessionHTTPClientTimeoutTierTests
//
// Plan 04-03 / POLL-08: Verify that `URLSessionHTTPClient(timeoutSeconds:)` correctly
// configures the underlying URLSession for both the remote 8s tier and the localhost 2s tier.
// Uses `configurationSnapshot()` internal accessor — no URLProtocol stub needed.

@Suite("URLSessionHTTPClientTimeoutTierTests")
struct URLSessionHTTPClientTimeoutTierTests {

    // MARK: Default (remote) tier — back-compat

    @Test("defaultInit_yieldsRemoteTier8sRequest")
    func defaultInit_yieldsRemoteTier8sRequest() {
        let client = URLSessionHTTPClient()
        #expect(client.configurationSnapshot().timeoutIntervalForRequest == 8.0)
    }

    @Test("defaultInit_yieldsRemoteTier32sResource")
    func defaultInit_yieldsRemoteTier32sResource() {
        // max(8 * 4, 30) = 32
        let client = URLSessionHTTPClient()
        #expect(client.configurationSnapshot().timeoutIntervalForResource == 32.0)
    }

    @Test("explicit8s_matchesDefault")
    func explicit8s_matchesDefault() {
        let client = URLSessionHTTPClient(timeoutSeconds: 8)
        #expect(client.configurationSnapshot().timeoutIntervalForRequest == 8.0)
    }

    // MARK: Localhost tier — 2s

    @Test("localhostTier2s_yields2sRequest")
    func localhostTier2s_yields2sRequest() {
        let client = URLSessionHTTPClient(timeoutSeconds: 2)
        #expect(client.configurationSnapshot().timeoutIntervalForRequest == 2.0)
    }

    @Test("localhostTier2s_yields30sResourceFloor")
    func localhostTier2s_yields30sResourceFloor() {
        // max(2 * 4, 30) = 30 — floor preserves cold-socket overhead budget
        let client = URLSessionHTTPClient(timeoutSeconds: 2)
        #expect(client.configurationSnapshot().timeoutIntervalForResource == 30.0)
    }

    // MARK: Scaling math regression

    @Test("unusual_15sTimeoutScalesResourceTo60")
    func unusual_15sTimeoutScalesResourceTo60() {
        // max(15 * 4, 30) = 60
        let client = URLSessionHTTPClient(timeoutSeconds: 15)
        #expect(client.configurationSnapshot().timeoutIntervalForResource == 60.0)
    }

    // MARK: POLL-08 invariants preserved on both tiers

    @Test("pollSettings_unchanged")
    func pollSettings_unchanged() {
        let remote = URLSessionHTTPClient(timeoutSeconds: 8)
        let local = URLSessionHTTPClient(timeoutSeconds: 2)

        for client in [remote, local] {
            let cfg = client.configurationSnapshot()
            #expect(cfg.waitsForConnectivity == false)
            #expect(cfg.httpMaximumConnectionsPerHost == 6)
            #expect(cfg.requestCachePolicy == .reloadIgnoringLocalCacheData)
        }
    }

    // MARK: Distinct URLSession instances

    @Test("twoInstances_areDistinctURLSessions")
    func twoInstances_areDistinctURLSessions() {
        let clientA = URLSessionHTTPClient(timeoutSeconds: 8)
        let clientB = URLSessionHTTPClient(timeoutSeconds: 2)

        // Each URLSessionHTTPClient owns a separate URLSession — configurations must be
        // different object instances (per-tier invariant; no shared backing store).
        let cfgA = clientA.configurationSnapshot()
        let cfgB = clientB.configurationSnapshot()
        #expect(ObjectIdentifier(cfgA) != ObjectIdentifier(cfgB))
    }
}

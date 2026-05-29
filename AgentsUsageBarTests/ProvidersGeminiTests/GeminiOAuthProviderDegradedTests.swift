import Testing
import Foundation
@testable import AgentsUsageBar

// Fixtures + fakes are shared with GeminiOAuthProviderTests (same target).
//
// This suite focuses on the degraded-UX surface (D-11), cross-provider
// isolation invariant (GEMINI-04), and the refresh-failure propagation
// carve-out.

// MARK: - Fixture helpers (file-private to avoid collisions)

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func loadFixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

private let quotaPath = GeminiOAuthProvider.quotaURL.path
private let tierPath = GeminiOAuthProvider.tierURL.path

// MARK: - GeminiOAuthProviderDegradedTests

@Suite("GeminiOAuthProviderDegradedTests", .serialized)
struct GeminiOAuthProviderDegradedTests {

    // MARK: - I. Degraded UX with no prior snapshot

    @Test func degraded_noPriorSnapshot_returnsTaggedMutedRow() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeProviderHTTPClient()
        http.responses[quotaPath] = [.failure(HTTPError(status: 500))]
        http.responses[tierPath] = [.failure(HTTPError(status: 500))]
        let oauth = FakeProviderOAuthClient(fresh: [.ok("FAKE-bearer-I")])

        let provider = GeminiOAuthProvider(http: http, oauth: oauth)
        let snap = try await provider.fetch(now: now)

        // Muted no-data shape.
        #expect(snap.quota == nil)
        #expect(snap.quotaWindows == nil)
        #expect(snap.tooltipLabel == nil)
        #expect(snap.tokensToday == nil)
        #expect(snap.costTodayUSD == nil)
        // D-11 marker.
        #expect(snap.raw["note"] == "usage-temporarily-unavailable")
        // lastStatus is typed error (NOT .ok).
        let status = await provider.status()
        switch status {
        case .ok: Issue.record("Expected non-ok status; got .ok")
        default: break
        }
    }

    // MARK: - J. Degraded UX with prior snapshot — D-11 cached-dim

    @Test func degraded_priorSnapshot_reusesQuotaButTagsDegraded() async throws {
        let now1 = Date(timeIntervalSince1970: 1_780_000_000)
        let now2 = Date(timeIntervalSince1970: 1_780_000_300)
        let http = FakeProviderHTTPClient()
        http.responses[quotaPath] = [
            .success(try loadFixtureData("gemini-quota-response-fixture.json")),
            .failure(HTTPError(status: 503)),
        ]
        http.responses[tierPath] = [
            .success(try loadFixtureData("gemini-loadcodeassist-fixture.json")),
            .failure(HTTPError(status: 503)),
        ]
        let oauth = FakeProviderOAuthClient(
            fresh: [.ok("FAKE-bearer-J1"), .ok("FAKE-bearer-J2")]
        )

        let provider = GeminiOAuthProvider(http: http, oauth: oauth)
        let happy = try await provider.fetch(now: now1)
        #expect(happy.quotaWindows?.count == 3)
        #expect(happy.tooltipLabel == "Free")

        let degraded = try await provider.fetch(now: now2)

        // Cached values reused.
        #expect(degraded.quotaWindows?.count == 3)
        #expect(degraded.tooltipLabel == "Free")
        // Updated asOf — current poll time.
        #expect(degraded.asOf == now2)
        // D-11 markers stamped.
        #expect(degraded.raw["note"] == "usage-temporarily-unavailable")
        #expect(degraded.raw["degraded"] == "true")
        // lastStatus is .stale(...) (carries the underlying error).
        let status = await provider.status()
        switch status {
        case .stale: break
        default: Issue.record("Expected .stale status, got \(status)")
        }
    }

    // MARK: - K. 401 retry exhaustion → degraded UX

    @Test func lazy401_retryAlsoFails_entersDegraded() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeProviderHTTPClient()
        http.responses[quotaPath] = [
            .failure(HTTPError(status: 401)),
            .failure(HTTPError(status: 401)),
        ]
        http.responses[tierPath] = [.failure(HTTPError(status: 500))]
        let oauth = FakeProviderOAuthClient(
            fresh: [.ok("FAKE-bearer-K-fresh")],
            retry: [.ok("FAKE-bearer-K-retry")]
        )

        let provider = GeminiOAuthProvider(http: http, oauth: oauth)
        let snap = try await provider.fetch(now: now)

        // No prior snapshot → muted + tagged degraded.
        #expect(snap.raw["note"] == "usage-temporarily-unavailable")
        let status = await provider.status()
        switch status {
        case .ok: Issue.record("Expected non-ok status; got .ok")
        default: break
        }
        // Retry was attempted exactly once (single-shot rule).
        let retryCalls = await oauth.retryCallCount
        #expect(retryCalls == 1)
    }

    // MARK: - L. OAuth refresh failure propagates (GEMINI-04 carve-out)

    @Test func oauthRefreshFailed_propagates_doesNotConvertToDegraded() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeProviderHTTPClient()
        // Both v1internal endpoints unreachable — irrelevant because
        // STEP 0 throws before the body of fetch even runs them.
        http.responses[quotaPath] = [.failure(HTTPError(status: 500))]
        http.responses[tierPath] = [.failure(HTTPError(status: 500))]
        let oauth = FakeProviderOAuthClient(
            fresh: [.throwError(GeminiOAuthError.refreshFailed(status: 400))]
        )

        let provider = GeminiOAuthProvider(http: http, oauth: oauth)
        await #expect(throws: GeminiOAuthError.refreshFailed(status: 400)) {
            _ = try await provider.fetch(now: now)
        }
        // After the throw, status reflects an error.
        let status = await provider.status()
        switch status {
        case .error: break
        default: Issue.record("Expected .error after refreshFailed; got \(status)")
        }
    }

    // MARK: - M. .notSignedIn → muted "No data yet" row, NO throw

    @Test func notSignedIn_returnsMutedNoData() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeProviderHTTPClient()
        let oauth = FakeProviderOAuthClient(
            fresh: [.throwError(GeminiOAuthError.notSignedIn)]
        )

        let provider = GeminiOAuthProvider(http: http, oauth: oauth)
        let snap = try await provider.fetch(now: now)

        // Muted no-data shape (Pitfall 9 — NO degraded tag because the
        // user isn't signed in, this is the "configure me" state).
        #expect(snap.quota == nil)
        #expect(snap.quotaWindows == nil)
        #expect(snap.raw["status"] == "no-data-yet")
        #expect(snap.raw["note"] == nil)
        let status = await provider.status()
        #expect(status == .unauthenticated)
    }

    // MARK: - N. Cross-provider isolation regression — all errors converted

    @Test func crossProviderIsolation_arbitrary5xxNeverThrows() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeProviderHTTPClient()
        http.responses[quotaPath] = [.failure(HTTPError(status: 500))]
        http.responses[tierPath] = [.failure(HTTPError(status: 500))]
        let oauth = FakeProviderOAuthClient(fresh: [.ok("FAKE-bearer-N")])

        let provider = GeminiOAuthProvider(http: http, oauth: oauth)
        // Must NOT throw.
        let snap = try await provider.fetch(now: now)
        #expect(snap.raw["note"] == "usage-temporarily-unavailable")
    }

    // MARK: - O. Notification suppression marker — exact string

    @Test func degradedSnapshot_carriesExactSuppressionMarker() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let http = FakeProviderHTTPClient()
        http.responses[quotaPath] = [.failure(HTTPError(status: 503))]
        http.responses[tierPath] = [.failure(HTTPError(status: 503))]
        let oauth = FakeProviderOAuthClient(fresh: [.ok("FAKE-bearer-O")])

        let provider = GeminiOAuthProvider(http: http, oauth: oauth)
        let snap = try await provider.fetch(now: now)

        // Plan 03-08 keys on this EXACT constant.
        #expect(snap.raw["note"] == "usage-temporarily-unavailable")
        // Mirror the production constant so a future rename surfaces
        // here too.
        #expect(snap.raw["note"] == GeminiOAuthProvider.degradedNote)
    }
}

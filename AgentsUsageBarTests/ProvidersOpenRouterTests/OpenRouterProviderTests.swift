import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - FakeOpenRouterClient

/// Test double for `OpenRouterClient`.
/// Stores pre-configured `Result` values and returns them on each call.
final class FakeOpenRouterClient: OpenRouterClient, @unchecked Sendable {
    var creditsResult: Result<OpenRouterCreditsResponse, Error>
    var keyResult: Result<OpenRouterKeyResponse, Error>

    init(
        creditsResult: Result<OpenRouterCreditsResponse, Error>,
        keyResult: Result<OpenRouterKeyResponse, Error>
    ) {
        self.creditsResult = creditsResult
        self.keyResult = keyResult
    }

    func getCredits() async throws -> OpenRouterCreditsResponse {
        try creditsResult.get()
    }

    func getKey() async throws -> OpenRouterKeyResponse {
        try keyResult.get()
    }
}

// MARK: - FakeCacheStore

/// In-memory test double for `CacheStore`.
/// Named `FakeCacheStore` per plan B9 namespace gate (NOT `InMemoryCacheStore`).
final class FakeCacheStore: CacheStore, @unchecked Sendable {
    private var baselines: [ProviderID: BaselineRecord] = [:]
    private var providers: [ProviderID: ProviderState] = [:]

    func loadAll() -> [ProviderID: ProviderState] { providers }

    func save(_ providers: [ProviderID: ProviderState]) {
        self.providers = providers
    }

    func baseline(for id: ProviderID, on now: Date) -> BaselineRecord? {
        baselines[id]
    }

    func maintainBaseline(for id: ProviderID, now: Date, currentValue: Double) {
        let today = TodayHelper.formatYYYYMMDD(now)
        let existing = baselines[id]
        let newRecord: BaselineRecord
        if existing == nil || existing!.date != today {
            newRecord = BaselineRecord(value: currentValue, date: today, lastValue: currentValue, lastUpdated: now)
        } else if currentValue < existing!.value {
            newRecord = BaselineRecord(value: currentValue, date: today, lastValue: currentValue, lastUpdated: now)
        } else {
            newRecord = BaselineRecord(value: existing!.value, date: today, lastValue: currentValue, lastUpdated: now)
        }
        baselines[id] = newRecord
    }

    /// Test helper — seed a baseline record directly.
    func seedBaseline(_ record: BaselineRecord, for id: ProviderID) {
        baselines[id] = record
    }

    // MARK: - CacheStore transcript offset conformance (Plan 02.01)

    private var transcriptOffsets: [String: TranscriptOffset] = [:]

    func transcriptOffset(forURL urlString: String) -> TranscriptOffset? {
        transcriptOffsets[urlString]
    }

    func setTranscriptOffset(_ offset: TranscriptOffset) {
        transcriptOffsets[offset.url] = offset
    }

    func allTranscriptOffsets() -> [String: TranscriptOffset] {
        transcriptOffsets
    }
}

// MARK: - Fixture helpers

private func makeCreditsResponse(totalCredits: Double, totalUsage: Double) -> OpenRouterCreditsResponse {
    OpenRouterCreditsResponse(data: .init(totalCredits: totalCredits, totalUsage: totalUsage))
}

private func makeKeyWithLimit() -> OpenRouterKeyResponse {
    OpenRouterKeyResponse(data: .init(
        label: "fake-label",
        limit: 10.0,
        limitReset: nil,
        limitRemaining: 1.80,
        includeByokInLimit: false,
        usage: 8.20,
        usageDaily: 1.10,
        usageWeekly: 5.30,
        usageMonthly: 8.20,
        byokUsage: 0.0,
        byokUsageDaily: 0.0,
        byokUsageWeekly: 0.0,
        byokUsageMonthly: 0.0,
        isFreeTier: false
    ))
}

private func makeKeyNoLimit() -> OpenRouterKeyResponse {
    OpenRouterKeyResponse(data: .init(
        label: "fake-label",
        limit: nil,
        limitReset: nil,
        limitRemaining: nil,
        includeByokInLimit: false,
        usage: 42.50,
        usageDaily: 0.30,
        usageWeekly: 12.10,
        usageMonthly: 42.50,
        byokUsage: 0.0,
        byokUsageDaily: 0.0,
        byokUsageWeekly: 0.0,
        byokUsageMonthly: 0.0,
        isFreeTier: false
    ))
}

// MARK: - OpenRouterProviderTests

@Suite("OpenRouterProviderTests")
struct OpenRouterProviderTests {

    private func makeProvider(
        credits: OpenRouterCreditsResponse,
        key: OpenRouterKeyResponse,
        cache: FakeCacheStore = FakeCacheStore()
    ) -> OpenRouterProvider {
        let client = FakeOpenRouterClient(
            creditsResult: .success(credits),
            keyResult: .success(key)
        )
        return OpenRouterProvider(client: client, cache: cache, clock: SystemClock())
    }

    // MARK: Test 1: Happy path with limit — verify balance, quota, tokensToday

    @Test("fetch_happyPath_withLimit_buildsSnapshot")
    func fetch_happyPath_withLimit_buildsSnapshot() async throws {
        let now = Date()
        let provider = makeProvider(
            credits: makeCreditsResponse(totalCredits: 100.50, totalUsage: 25.30),
            key: makeKeyWithLimit()
        )
        let snap = try await provider.fetch(now: now)
        // balance = 100.50 - 25.30 = 75.20
        #expect(snap.balanceUSD == Decimal(75.20))
        #expect(snap.quota?.limit == 10.0)
        #expect(snap.quota?.used == 8.20)
        #expect(snap.quota?.remaining == 1.80)
        #expect(snap.tokensToday == nil)
        #expect(snap.providerID == .openrouter)
    }

    // MARK: Test 2: No-limit account — quota must be nil (D-14 / ROUTER-03)

    @Test("fetch_happyPath_noLimit_quotaIsNil")
    func fetch_happyPath_noLimit_quotaIsNil() async throws {
        let now = Date()
        let provider = makeProvider(
            credits: makeCreditsResponse(totalCredits: 100.0, totalUsage: 42.50),
            key: makeKeyNoLimit()
        )
        let snap = try await provider.fetch(now: now)
        #expect(snap.quota == nil)
        #expect(snap.tokensToday == nil)
    }

    // MARK: Test 3: 401 auth error — throws, status becomes .error(.auth)

    @Test("fetch_creditsAuthError_throwsAndSetsErrorStatus")
    func fetch_creditsAuthError_throwsAndSetsErrorStatus() async throws {
        let client = FakeOpenRouterClient(
            creditsResult: .failure(HTTPError(status: 401)),
            keyResult: .success(makeKeyWithLimit())
        )
        let provider = OpenRouterProvider(client: client, cache: FakeCacheStore(), clock: SystemClock())
        await #expect(throws: (any Error).self) {
            try await provider.fetch(now: Date())
        }
        let status = await provider.status()
        if case .error(let e) = status {
            #expect(e.kind == .auth)
        } else {
            Issue.record("Expected .error(.auth) status, got \(status)")
        }
    }

    // MARK: Test 4: 503 server error on key — throws, status becomes .error(.http)

    @Test("fetch_keyServerError_throwsAndSetsErrorStatus")
    func fetch_keyServerError_throwsAndSetsErrorStatus() async throws {
        let client = FakeOpenRouterClient(
            creditsResult: .success(makeCreditsResponse(totalCredits: 100.0, totalUsage: 20.0)),
            keyResult: .failure(HTTPError(status: 503))
        )
        let provider = OpenRouterProvider(client: client, cache: FakeCacheStore(), clock: SystemClock())
        await #expect(throws: (any Error).self) {
            try await provider.fetch(now: Date())
        }
        let status = await provider.status()
        if case .error(let e) = status {
            #expect(e.kind == .http)
        } else {
            Issue.record("Expected .error(.http) status, got \(status)")
        }
    }

    // MARK: Test 5: After success, status is .ok

    @Test("fetch_lastStatusOK_afterSuccess")
    func fetch_lastStatusOK_afterSuccess() async throws {
        let now = Date()
        let provider = makeProvider(
            credits: makeCreditsResponse(totalCredits: 50.0, totalUsage: 10.0),
            key: makeKeyNoLimit()
        )
        _ = try await provider.fetch(now: now)
        let status = await provider.status()
        if case .ok(let lastSuccess) = status {
            #expect(lastSuccess == now)
        } else {
            Issue.record("Expected .ok status after successful fetch, got \(status)")
        }
    }
}

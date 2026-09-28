import CryptoKit
import Foundation
import Testing
@testable import AgentsUsageBar

// SPEC T3: V1 V2 V5 V6 V7 V8 V9 V10 V11 V13 V14 V17 V18 V19. Synthetic data only —
// usage values, keys and the /api/me payload below are made up.

/// Scripted `HTTPClient`: answers by "METHOD /path", records every request.
final class FakeOllamaCloudHTTPClient: HTTPClient, @unchecked Sendable {
    struct Call: Equatable {
        let method: String
        let url: URL
        let bearer: String?
        let authorization: String?
    }

    private let lock = NSLock()
    private var scripted: [String: [Result<Data, Error>]] = [:]
    private(set) var calls: [Call] = []

    func script(_ method: String, _ path: String, _ results: Result<Data, Error>...) {
        lock.withLock { scripted["\(method) \(path)", default: []] += results }
    }

    func count(_ method: String, _ path: String) -> Int {
        lock.withLock { calls.filter { $0.method == method && $0.url.path == path }.count }
    }

    private func answer<T: Decodable>(_ method: String, _ url: URL, bearer: Secret?,
                                      headers: [String: String], as type: T.Type) throws -> T {
        let result: Result<Data, Error> = lock.withLock {
            calls.append(Call(method: method, url: url, bearer: bearer?.revealForRequest(),
                              authorization: headers["Authorization"]))
            let key = "\(method) \(url.path)"
            guard var queue = scripted[key], !queue.isEmpty else { return .failure(HTTPError(status: 599)) }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            scripted[key] = queue
            return next
        }
        return try JSONDecoder().decode(T.self, from: result.get())
    }

    func get<T: Decodable & Sendable>(_ url: URL, bearer: Secret, extraHeaders: [String: String],
                                      useSnakeCaseConversion: Bool, as type: T.Type) async throws -> T {
        try answer("GET", url, bearer: bearer, headers: extraHeaders, as: type)
    }

    func get<T: Decodable & Sendable>(_ url: URL, bearer: Secret?, extraHeaders: [String: String],
                                      useSnakeCaseConversion: Bool, as type: T.Type) async throws -> T {
        try answer("GET", url, bearer: bearer, headers: extraHeaders, as: type)
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL, body: Body, extraHeaders: [String: String], as type: T.Type) async throws -> T {
        try answer("POST", url, bearer: nil, headers: extraHeaders, as: type)
    }

    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL, body: Body, bearer: Secret, extraHeaders: [String: String], as type: T.Type) async throws -> T {
        try answer("POST", url, bearer: bearer, headers: extraHeaders, as: type)
    }

    func postFormURLEncoded<T: Decodable & Sendable>(
        _ url: URL, formFields: [(String, String)], extraHeaders: [String: String], as type: T.Type) async throws -> T {
        try answer("POST", url, bearer: nil, headers: extraHeaders, as: type)
    }
}

@Suite("OllamaCloudProviderTests")
struct OllamaCloudProviderTests {

    static let usageJSON = Data(#"""
    {"activity":{"cost":"1.23456","models":[],"period":{"type":"last_4_weeks","starting_at":"2026-01-01T00:00:00Z","ending_at":"2026-01-29T00:00:00Z"}},
     "limits":{"monthly":{"usage":0.25,"models":[]},"weekly":{"usage":0.9}}}
    """#.utf8)
    /// Made-up personal fields: prove they are never decoded or surfaced (V19).
    static let meJSON = Data(#"""
    {"ID":"00000000-0000-0000-0000-000000000000","Name":"example-user","Email":"user@example.invalid",
     "AvatarURL":"https://example.invalid/a.png","Bio":"","Links":[],"CreatedAt":"2026-01-01T00:00:00Z","Plan":"pro"}
    """#.utf8)
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let envKey = OllamaCloudCredential.apiKey(Secret("fake-ollama-env"), source: .env)

    static func provider(_ http: FakeOllamaCloudHTTPClient,
                         credential: OllamaCloudCredential = envKey,
                         billingDay: Int? = nil) -> OllamaCloudProvider {
        let (config, device) = Self.sources(credential, billingDay: billingDay)
        return OllamaCloudProvider(http: http, loadConfig: { config }, loadDevice: { device },
                                   timeZone: TimeZone(identifier: "Asia/Bangkok")!)
    }

    /// Config + device key that make `resolve` yield `credential`.
    static func sources(_ credential: OllamaCloudCredential, billingDay: Int? = nil)
        -> (OllamaCloudConfig, OllamaDeviceSigner?) {
        switch credential {
        case .apiKey(let key, let source):
            return (OllamaCloudConfig(enabled: true, apiKey: key, apiKeySource: source, billingDay: billingDay), nil)
        case .device(let signer):
            return (OllamaCloudConfig(enabled: true, apiKey: nil, apiKeySource: nil, billingDay: billingDay), signer)
        }
    }

    static func happyHTTP() -> FakeOllamaCloudHTTPClient {
        let http = FakeOllamaCloudHTTPClient()
        http.script("GET", "/api/usage", .success(usageJSON))
        http.script("POST", "/api/me", .success(meJSON))
        return http
    }

    // MARK: - Mapping

    @Test func fetch_mapsMonthlyWindowTooltipAndRaw() async throws {
        let snap = try await Self.provider(Self.happyHTTP()).fetch(now: Self.now)

        let window = try #require(snap.quotaWindows?.first)
        #expect(snap.quotaWindows?.count == 1)          // weekly ignored (C4)
        #expect(window.name == "mo")
        #expect(window.utilization == 0.25)
        #expect(window.duration == nil)                  // V24: compact labels it `mo`
        #expect(window.resetsAt == nil)                  // no billing_day → ↻ unknown
        #expect(snap.quota == Quota(used: 0.25, limit: 1, remaining: 0.75))
        #expect(snap.costTodayUSD == nil)
        #expect(snap.tokensToday == nil)
        #expect(snap.raw == ["plan": "pro", "ownSpendLast4WeeksUSD": "1.23456", "credentialSource": "env"])
        #expect(snap.tooltipLabel == "Pro\nyour last 4 weeks: $1.23\nvia OLLAMA_API_KEY")
    }

    @Test func capabilities_quotaOnlyRemote() {
        let caps = Self.provider(FakeOllamaCloudHTTPClient()).capabilities
        #expect(caps.hasQuota && !caps.hasCost && !caps.hasTokens && !caps.isLocal)
    }

    @Test(arguments: [(1.4, 1.0), (-0.2, 0.0), (0.0, 0.0), (1.0, 1.0)])
    func fetch_clampsUtilization(raw: Double, expected: Double) async throws {
        let http = FakeOllamaCloudHTTPClient()
        http.script("GET", "/api/usage", .success(Data(#"{"limits":{"monthly":{"usage":\#(raw)}}}"#.utf8)))
        let snap = try await Self.provider(http).fetch(now: Self.now)
        #expect(snap.quotaWindows?.first?.utilization == expected)
    }

    @Test(arguments: [#"{}"#, #"{"limits":{}}"#, #"{"limits":{"monthly":{}}}"#, #"{"surprise":[1,2]}"#])
    func fetch_missingMonthly_noWindowButOk(json: String) async throws {
        let http = FakeOllamaCloudHTTPClient()
        http.script("GET", "/api/usage", .success(Data(json.utf8)))
        let provider = Self.provider(http)
        let snap = try await provider.fetch(now: Self.now)
        #expect(snap.quotaWindows == nil)
        #expect(snap.quota == nil)
        #expect(snap.tooltipLabel == "via OLLAMA_API_KEY")
        if case .ok = await provider.status() {} else { Issue.record("expected .ok") }
    }

    @Test func fetch_unparseableCost_omitted() async throws {
        let http = FakeOllamaCloudHTTPClient()
        http.script("GET", "/api/usage", .success(Data(#"{"activity":{"cost":"n/a"},"limits":{"monthly":{"usage":0.5}}}"#.utf8)))
        let snap = try await Self.provider(http).fetch(now: Self.now)
        #expect(snap.raw["ownSpendLast4WeeksUSD"] == nil)
        #expect(snap.tooltipLabel == "via OLLAMA_API_KEY")
    }

    @Test func fetch_billingDay_setsReset() async throws {
        let snap = try await Self.provider(Self.happyHTTP(), billingDay: 15).fetch(now: Self.now)
        #expect(snap.quotaWindows?.first?.resetsAt != nil)
    }

    // MARK: - Transport (V1)

    @Test func apiKey_sendsBearerToBothEndpoints() async throws {
        let http = Self.happyHTTP()
        _ = try await Self.provider(http).fetch(now: Self.now)
        #expect(http.calls.map(\.method) == ["GET", "POST"])
        #expect(http.calls.map(\.url.absoluteString) == ["https://ollama.com/api/usage", "https://ollama.com/api/me"])
        #expect(http.calls.allSatisfy { $0.bearer == "fake-ollama-env" && $0.authorization == nil })
    }

    @Test func device_signsBothEndpoints() async throws {
        let http = Self.happyHTTP()
        let signer = try OllamaDeviceSigner(openSSH: TestOpenSSHKey.encode(seed: OllamaDeviceSignerTests.fixedSeed))
        let snap = try await Self.provider(http, credential: .device(signer)).fetch(now: Self.now)

        #expect(http.calls.map(\.url.absoluteString) == [
            "https://ollama.com/api/usage?ts=1790000000",
            "https://ollama.com/api/me?ts=1790000000",
        ])
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: OllamaDeviceSignerTests.fixedSeed).publicKey
        for (call, challenge) in zip(http.calls, ["GET,/api/usage?ts=1790000000", "POST,/api/me?ts=1790000000"]) {
            #expect(call.bearer == nil)
            let parts = try #require(call.authorization?.split(separator: ":"))
            #expect(String(parts[0]) == OllamaDeviceSignerTests.fixedPublicKeyField)
            let sig = try #require(Data(base64Encoded: String(parts[1])))
            #expect(publicKey.isValidSignature(sig, for: Data(challenge.utf8)))
        }
        #expect(snap.raw["credentialSource"] == "device")
        #expect(snap.tooltipLabel?.hasSuffix("via ollama signin") == true)
    }

    // MARK: - Failures (V5, V18)

    @Test(arguments: [
        (OllamaCloudCredential.apiKey(Secret("k"), source: .env), "check OLLAMA_API_KEY"),
        (OllamaCloudCredential.apiKey(Secret("k"), source: .config), "check [ollama] api_key"),
    ])
    func unauthorized_throwsAuthWithHint(credential: OllamaCloudCredential, hint: String) async {
        for status in [401, 403] {
            let http = FakeOllamaCloudHTTPClient()
            http.script("GET", "/api/usage", .failure(HTTPError(status: status)))
            let provider = Self.provider(http, credential: credential)
            await #expect(throws: ProviderError(kind: .auth, message: hint)) { try await provider.fetch(now: Self.now) }
            #expect(await provider.status() == .error(ProviderError(kind: .auth, message: hint)))
            #expect(http.count("POST", "/api/me") == 0)
        }
    }

    @Test func unauthorized_device_hintsSignin() async throws {
        let http = FakeOllamaCloudHTTPClient()
        http.script("GET", "/api/usage", .failure(HTTPError(status: 401)))
        let signer = try OllamaDeviceSigner(openSSH: TestOpenSSHKey.encode(seed: OllamaDeviceSignerTests.fixedSeed))
        let provider = Self.provider(http, credential: .device(signer))
        await #expect(throws: ProviderError(kind: .auth, message: "run ollama signin")) { try await provider.fetch(now: Self.now) }
    }

    @Test func serverError_throwsHTTP_decodeError_throwsDecode() async {
        let http = FakeOllamaCloudHTTPClient()
        http.script("GET", "/api/usage", .failure(HTTPError(status: 502)), .success(Data("not json".utf8)))
        let provider = Self.provider(http)
        await #expect(throws: ProviderError(kind: .http, message: "HTTP 502")) { try await provider.fetch(now: Self.now) }
        do {
            _ = try await provider.fetch(now: Self.now)
            Issue.record("expected decode failure")
        } catch let error as ProviderError {
            #expect(error.kind == .decode)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: - Plan (V17, V19)

    @Test func plan_fetchedOncePerLaunch() async throws {
        let http = Self.happyHTTP()
        let provider = Self.provider(http)
        _ = try await provider.fetch(now: Self.now)
        let second = try await provider.fetch(now: Self.now)
        #expect(http.count("GET", "/api/usage") == 2)
        #expect(http.count("POST", "/api/me") == 1)
        #expect(second.raw["plan"] == "pro")
    }

    @Test func plan_failureOmitted_thenRetried() async throws {
        let http = FakeOllamaCloudHTTPClient()
        http.script("GET", "/api/usage", .success(Self.usageJSON))
        http.script("POST", "/api/me", .failure(HTTPError(status: 500)), .success(Self.meJSON))
        let provider = Self.provider(http)

        let first = try await provider.fetch(now: Self.now)
        #expect(first.raw["plan"] == nil)
        #expect(first.quotaWindows?.first?.utilization == 0.25)
        let second = try await provider.fetch(now: Self.now)
        #expect(second.raw["plan"] == "pro")
        #expect(http.count("POST", "/api/me") == 2)
    }

    @Test func me_decodesPlanOnly_personalFieldsNeverSurface() async throws {
        let decoded = try JSONDecoder().decode(OllamaMeResponse.self, from: Self.meJSON)
        #expect(decoded == OllamaMeResponse(plan: "pro"))
        #expect(Mirror(reflecting: decoded).children.count == 1)

        let snap = try await Self.provider(Self.happyHTTP()).fetch(now: Self.now)
        let surfaced = snap.raw.values.joined() + (snap.tooltipLabel ?? "")
        for secret in ["example-user", "user@example.invalid", "00000000-0000", "fake-ollama-env"] {
            #expect(!surfaced.contains(secret))
        }
    }

    @Test func plan_2xxWithoutPlan_notRePosted() async throws {
        let http = FakeOllamaCloudHTTPClient()
        http.script("GET", "/api/usage", .success(Self.usageJSON))
        http.script("POST", "/api/me", .success(Data(#"{"Email":"user@example.invalid"}"#.utf8)))
        let provider = Self.provider(http)
        _ = try await provider.fetch(now: Self.now)
        let second = try await provider.fetch(now: Self.now)
        #expect(http.count("POST", "/api/me") == 1)
        #expect(second.raw["plan"] == nil)
    }

    @Test func fetch_cost_numericPrefixGarbage_omitted() async throws {
        let http = FakeOllamaCloudHTTPClient()
        http.script("GET", "/api/usage", .success(Data(#"{"activity":{"cost":"1.5abc"},"limits":{"monthly":{"usage":0.5}}}"#.utf8)))
        let snap = try await Self.provider(http).fetch(now: Self.now)
        #expect(snap.raw["ownSpendLast4WeeksUSD"] == nil)
    }

    // MARK: - Per-fetch credential (V6, V25)

    @Test func changedCredential_appliesNextPoll_andRefetchesPlan() async throws {
        let box = Locked(OllamaCloudProviderTests.sources(.apiKey(Secret("fake-bad-key"), source: .config)).0)
        let http = FakeOllamaCloudHTTPClient()
        http.script("GET", "/api/usage", .failure(HTTPError(status: 401)), .success(Self.usageJSON))
        http.script("POST", "/api/me", .success(Self.meJSON))
        let provider = OllamaCloudProvider(http: http, loadConfig: { box.value }, loadDevice: { nil })

        await #expect(throws: ProviderError(kind: .auth, message: "check [ollama] api_key")) {
            try await provider.fetch(now: Self.now)
        }
        box.value = OllamaCloudConfig(enabled: true, apiKey: Secret("fake-good-key"), apiKeySource: .config, billingDay: 3)
        let snap = try await provider.fetch(now: Self.now)

        let usageCalls = http.calls.filter { $0.url.path == "/api/usage" }
        #expect(usageCalls.map(\.bearer) == ["fake-bad-key", "fake-good-key"])
        if case .ok = await provider.status() {} else { Issue.record("expected .ok after fix") }
        #expect(snap.quotaWindows?.first?.resetsAt != nil)       // billing_day re-read too
        #expect(snap.raw["plan"] == "pro")
    }

    @Test func credentialSourceChange_refetchesPlan() async throws {
        let signer = try OllamaDeviceSigner(openSSH: TestOpenSSHKey.encode(seed: OllamaDeviceSignerTests.fixedSeed))
        let box = Locked(OllamaCloudProviderTests.sources(Self.envKey).0)
        let http = Self.happyHTTP()
        let provider = OllamaCloudProvider(http: http, loadConfig: { box.value }, loadDevice: { signer })
        _ = try await provider.fetch(now: Self.now)
        _ = try await provider.fetch(now: Self.now)
        #expect(http.count("POST", "/api/me") == 1)
        box.value = .defaults                                    // key removed → device key
        let snap = try await provider.fetch(now: Self.now)
        #expect(http.count("POST", "/api/me") == 2)
        #expect(snap.raw["credentialSource"] == "device")
    }

    @Test func noCredentialAtFetch_throwsAuthHint() async {
        let http = FakeOllamaCloudHTTPClient()
        let provider = OllamaCloudProvider(http: http, loadConfig: { .defaults }, loadDevice: { nil })
        await #expect(throws: ProviderError(kind: .auth, message: "run ollama signin or set OLLAMA_API_KEY")) {
            try await provider.fetch(now: Self.now)
        }
        #expect(http.calls.isEmpty)
    }

    @Test func httpClient_hasNoURLCache() {
        #expect(URLSessionHTTPClient.makeConfiguration(timeoutSeconds: 8).urlCache == nil)
    }

    // MARK: - Reset (V8)

    static let bangkok = TimeZone(identifier: "Asia/Bangkok")!

    static func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = bangkok
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func nextReset_laterThisMonth() {
        #expect(OllamaCloudProvider.nextReset(billingDay: 15, after: Self.local(2026, 9, 10, 9), timeZone: Self.bangkok)
                == Self.local(2026, 9, 15))
    }

    @Test func nextReset_rollsToNextMonth() {
        #expect(OllamaCloudProvider.nextReset(billingDay: 15, after: Self.local(2026, 9, 28, 13), timeZone: Self.bangkok)
                == Self.local(2026, 10, 15))
    }

    @Test func nextReset_exactlyAtResetMoment_isNextMonth() {
        #expect(OllamaCloudProvider.nextReset(billingDay: 15, after: Self.local(2026, 9, 15), timeZone: Self.bangkok)
                == Self.local(2026, 10, 15))
    }

    @Test func nextReset_clampsToShortMonth() {
        #expect(OllamaCloudProvider.nextReset(billingDay: 31, after: Self.local(2027, 2, 10), timeZone: Self.bangkok)
                == Self.local(2027, 2, 28))
        #expect(OllamaCloudProvider.nextReset(billingDay: 31, after: Self.local(2027, 2, 28, 1), timeZone: Self.bangkok)
                == Self.local(2027, 3, 31))
        #expect(OllamaCloudProvider.nextReset(billingDay: 30, after: Self.local(2028, 2, 1), timeZone: Self.bangkok)
                == Self.local(2028, 2, 29))
    }

    @Test func nextReset_yearRollover() {
        #expect(OllamaCloudProvider.nextReset(billingDay: 5, after: Self.local(2026, 12, 20), timeZone: Self.bangkok)
                == Self.local(2027, 1, 5))
    }

    @Test func nextReset_localMidnightAcrossDST() {
        let ny = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ny
        func nyDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        }
        // DST ends 2026-11-01, starts 2027-03-14: resets stay at local midnight.
        #expect(OllamaCloudProvider.nextReset(billingDay: 5, after: nyDate(2026, 10, 20), timeZone: ny)
                == nyDate(2026, 11, 5))
        #expect(OllamaCloudProvider.nextReset(billingDay: 15, after: nyDate(2027, 3, 1), timeZone: ny)
                == nyDate(2027, 3, 15))
    }

    @Test(arguments: [nil, 0, 32, -1] as [Int?])
    func nextReset_unsetOrInvalid_nil(day: Int?) {
        #expect(OllamaCloudProvider.nextReset(billingDay: day, after: Self.now, timeZone: Self.bangkok) == nil)
    }

    // MARK: - Credential resolution (V1)

    @Test func resolve_explicitKeyWins_deviceNotLoaded() {
        var loaded = false
        let config = OllamaCloudConfig(enabled: true, apiKey: Secret("k"), apiKeySource: .config, billingDay: nil)
        let credential = OllamaCloudCredential.resolve(config: config) { loaded = true; return nil }
        #expect(credential?.sourceKey == "config")
        #expect(loaded == false)
    }

    @Test func resolve_noKey_usesDevice_orNil() throws {
        let signer = try OllamaDeviceSigner(openSSH: TestOpenSSHKey.encode(seed: OllamaDeviceSignerTests.fixedSeed))
        #expect(OllamaCloudCredential.resolve(config: .defaults) { signer }?.sourceKey == "device")
        #expect(OllamaCloudCredential.resolve(config: .defaults) { nil } == nil)
    }
}

// MARK: - Registration + store recovery (V2, V6)

@Suite("OllamaCloudRegistrationTests")
struct OllamaCloudRegistrationTests {

    @MainActor
    private func build(_ cloud: OllamaCloudConfig, device: OllamaDeviceSigner?) -> ProviderRegistry {
        let base = AppConfig.defaults
        let config = AppConfig(
            refreshInterval: base.refreshInterval, threshold: base.threshold, openrouter: base.openrouter,
            codex: base.codex, gemini: base.gemini, grok: base.grok, ollama: base.ollama,
            ollamaCloud: cloud, lmstudio: base.lmstudio, llamacpp: base.llamacpp, engines: []
        )
        return ProviderRegistryFactory.build(
            config: config,
            preferences: UserPreferencesStore(defaults: UserDefaults(suiteName: "test-ollama-cloud-\(UUID().uuidString)")!),
            http: FakeOllamaCloudHTTPClient(),
            localhostHTTP: FakeOllamaCloudHTTPClient(),
            cache: NoopCacheStore(),
            clock: SystemClock(),
            processCatalog: StaticProcessCatalog(),
            loadOllamaDeviceKey: { device },
            loadOllamaCloudConfig: { cloud }
        )
    }

    @MainActor
    @Test func registered_withKey_orDevice() throws {
        let keyed = OllamaCloudConfig(enabled: true, apiKey: Secret("k"), apiKeySource: .env, billingDay: nil)
        #expect(build(keyed, device: nil).providers.contains { $0.id == .ollamaCloud })
        let signer = try OllamaDeviceSigner(openSSH: TestOpenSSHKey.encode(seed: OllamaDeviceSignerTests.fixedSeed))
        #expect(build(.defaults, device: signer).providers.contains { $0.id == .ollamaCloud })
    }

    @MainActor
    @Test func notRegistered_noCredential_noPlaceholder() {
        let built = build(.defaults, device: nil)
        #expect(!built.providers.contains { $0.id == .ollamaCloud })
        #expect(!built.placeholders.contains { $0.providerID == .ollamaCloud })
    }

    @MainActor
    @Test func notRegistered_whenCloudDisabled() {
        let off = OllamaCloudConfig(enabled: false, apiKey: Secret("k"), apiKeySource: .env, billingDay: nil)
        #expect(!build(off, device: nil).providers.contains { $0.id == .ollamaCloud })
    }

    @MainActor
    @Test func store_recoversFromAuthErrorOnNextTick() async {
        let http = FakeOllamaCloudHTTPClient()
        http.script("GET", "/api/usage", .failure(HTTPError(status: 401)), .success(OllamaCloudProviderTests.usageJSON))
        http.script("POST", "/api/me", .success(OllamaCloudProviderTests.meJSON))
        let now = Date()
        let store = AggregateStore(
            registry: [OllamaCloudProviderTests.provider(http)],
            clock: VirtualClock(fixed: now),
            cache: AggFakeCacheStore(),
            thresholds: ThresholdEngine(),
            notifications: NoopNotificationManager()
        )

        await store.refresh(now: now)
        if case .ok = store.providers[.ollamaCloud]?.status {
            Issue.record("expected failure status after 401")
        }

        await store.refresh(now: now.addingTimeInterval(300))
        if case .ok = store.providers[.ollamaCloud]?.status {} else {
            Issue.record("expected .ok after credential fixed, got \(String(describing: store.providers[.ollamaCloud]?.status))")
        }
        #expect(http.count("GET", "/api/usage") == 2)
    }
}

/// Mutable box for closures that must see changes between fetches.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

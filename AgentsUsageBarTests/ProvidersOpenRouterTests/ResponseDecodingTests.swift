import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Fixture loading helper

private func loadFixture(named name: String) throws -> Data {
    // Use #filePath-relative path — Swift Testing bundles may not expose Bundle.module
    // without explicit resource declarations in the pbxproj Copy Bundle Resources phase.
    let thisFile = URL(fileURLWithPath: #filePath)
    let fixturesDir = thisFile
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    let url = fixturesDir.appendingPathComponent(name)
    return try Data(contentsOf: url)
}

private func makeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}

// MARK: - Tests

@Suite("ResponseDecodingTests")
struct ResponseDecodingTests {

    // MARK: Test 1: credits.success.json decodes correctly

    @Test("decodesCreditsSuccessJSON")
    func decodesCreditsSuccessJSON() throws {
        let data = try loadFixture(named: "credits.success.json")
        let response = try makeDecoder().decode(OpenRouterCreditsResponse.self, from: data)
        #expect(response.data.totalCredits == 100.50)
        #expect(response.data.totalUsage == 25.30)
    }

    // MARK: Test 2: key.with_limit.json decodes correctly

    @Test("decodesKeyWithLimit")
    func decodesKeyWithLimit() throws {
        let data = try loadFixture(named: "key.with_limit.json")
        let response = try makeDecoder().decode(OpenRouterKeyResponse.self, from: data)
        #expect(response.data.limit == 10.0)
        #expect(response.data.limitRemaining == 1.80)
        #expect(response.data.usage == 8.20)
        #expect(response.data.isFreeTier == false)
        #expect(response.data.label == "fake-label")
    }

    // MARK: Test 3: key.no_limit.json decodes with nil limit (D-14 / ROUTER-03)

    @Test("decodesKeyNoLimit")
    func decodesKeyNoLimit() throws {
        let data = try loadFixture(named: "key.no_limit.json")
        let response = try makeDecoder().decode(OpenRouterKeyResponse.self, from: data)
        #expect(response.data.limit == nil)
        #expect(response.data.limitRemaining == nil)
        #expect(response.data.limitReset == nil)
        #expect(response.data.usage == 42.50)
    }

    // MARK: Test 4: credits.unauthorized.json must NOT decode as a success response

    @Test("creditsErrorPayloadFails_atDecodeBoundary")
    func creditsErrorPayloadFails_atDecodeBoundary() throws {
        let data = try loadFixture(named: "credits.unauthorized.json")
        #expect(throws: (any Error).self) {
            try makeDecoder().decode(OpenRouterCreditsResponse.self, from: data)
        }
    }

    // MARK: Test 5: OpenRouterEndpoint builds correct URLs (ROUTER-04)

    @Test("endpointURLs_buildCorrectly")
    func endpointURLs_buildCorrectly() {
        // Default endpoint
        #expect(OpenRouterEndpoint.default.credits.absoluteString == "https://openrouter.ai/api/v1/credits")
        #expect(OpenRouterEndpoint.default.key.absoluteString == "https://openrouter.ai/api/v1/key")

        // Custom base URL override (ROUTER-04)
        let custom = OpenRouterEndpoint(baseURL: URL(string: "https://custom.example/api/v1")!)
        #expect(custom.credits.absoluteString == "https://custom.example/api/v1/credits")
        #expect(custom.key.absoluteString == "https://custom.example/api/v1/key")
    }

    // MARK: Test 6: snake_case → camelCase decoding strategy applied

    @Test("snakeCaseDecodingApplied")
    func snakeCaseDecodingApplied() throws {
        // Verify that limit_remaining (snake_case JSON key) decodes into limitRemaining (camelCase property).
        // This is the .convertFromSnakeCase invariant: if the strategy is missing, this decode will fail.
        let json = """
        {
          "data": {
            "label": "test",
            "limit": 5.0,
            "limit_reset": null,
            "limit_remaining": 3.5,
            "include_byok_in_limit": true,
            "usage": 1.5,
            "usage_daily": 0.5,
            "usage_weekly": 1.0,
            "usage_monthly": 1.5,
            "byok_usage": 0.0,
            "byok_usage_daily": 0.0,
            "byok_usage_weekly": 0.0,
            "byok_usage_monthly": 0.0,
            "is_free_tier": false
          }
        }
        """.data(using: .utf8)!
        let response = try makeDecoder().decode(OpenRouterKeyResponse.self, from: json)
        // limitRemaining must be 3.5 — proves snake_case → camelCase worked
        #expect(response.data.limitRemaining == 3.5)
        #expect(response.data.includeByokInLimit == true)
    }
}

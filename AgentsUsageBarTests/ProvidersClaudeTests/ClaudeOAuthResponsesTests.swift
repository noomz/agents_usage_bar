import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Fixture loading helper

private func loadFixtureData(named name: String) throws -> Data {
    let thisFile = URL(fileURLWithPath: #filePath)
    let fixtureURL = thisFile
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    return try Data(contentsOf: fixtureURL)
}

private func decodeUsage(_ data: Data) throws -> ClaudeUsageResponse {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(ClaudeUsageResponse.self, from: data)
}

private func decodeRefresh(_ data: Data) throws -> ClaudeTokenRefreshResponse {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(ClaudeTokenRefreshResponse.self, from: data)
}

// MARK: - ClaudeOAuthResponsesTests

@Suite("ClaudeOAuthResponsesTests")
struct ClaudeOAuthResponsesTests {

    @Test func decodes_full_usage_response() throws {
        let data = try loadFixtureData(named: "oauth-usage-success.json")
        let response = try decodeUsage(data)
        #expect(response.fiveHour?.utilization == 67.5)
        #expect(response.sevenDay?.utilization == 32.1)
        #expect(response.sevenDaySonnet?.utilization == 28.0)
        #expect(response.sevenDayOpus?.utilization == 12.5)
    }

    @Test func decodes_partial_usage_response() throws {
        let data = try loadFixtureData(named: "oauth-usage-partial.json")
        let response = try decodeUsage(data)
        #expect(response.fiveHour?.utilization == 12.0)
        #expect(response.sevenDay == nil)
        #expect(response.sevenDaySonnet == nil)
        #expect(response.sevenDayOpus == nil)
    }

    @Test func decodes_refresh_response_with_rotated_refresh_token() throws {
        let data = try loadFixtureData(named: "oauth-refresh-success.json")
        let response = try decodeRefresh(data)
        #expect(response.accessToken == "fake-rotated-access-token-XXXX")
        #expect(response.refreshToken == "fake-rotated-refresh-token-YYYY")
        #expect(response.expiresIn == 3600)
    }

    @Test func decodes_refresh_response_without_rotated_refresh_token() throws {
        let json = #"{"access_token":"x","expires_in":7200}"#.data(using: .utf8)!
        let response = try decodeRefresh(json)
        #expect(response.accessToken == "x")
        #expect(response.refreshToken == nil)
        #expect(response.expiresIn == 7200)
    }

    @Test func snakeCaseDecoding_resetsAt_and_fiveHour() throws {
        let data = try loadFixtureData(named: "oauth-usage-success.json")
        let response = try decodeUsage(data)
        // five_hour → fiveHour (camelCase decode invariant)
        #expect(response.fiveHour != nil)
        // resets_at → resetsAt
        #expect(response.fiveHour?.resetsAt == "2026-05-13T20:00:00.000+00:00")
    }

    @Test func iso_resetsAt_decodes_with_fractional_seconds() throws {
        let data = try loadFixtureData(named: "oauth-usage-success.json")
        let response = try decodeUsage(data)
        let resetsAtString = try #require(response.fiveHour?.resetsAt)

        // resetsAt is stored as String; verify ISO8601DateFormatter parses it correctly
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = try #require(formatter.date(from: resetsAtString))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let parts = cal.dateComponents([.year, .month, .day], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 5)
        #expect(parts.day == 13)
    }
}

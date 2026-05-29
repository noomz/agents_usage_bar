import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Fixture helpers

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func loadFixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

// MARK: - GeminiQuotaResponseTests

@Suite("GeminiQuotaResponseTests")
struct GeminiQuotaResponseTests {

    // MARK: - 1. Decode 3-bucket fixture

    @Test func decodes_threeBucketFixture() throws {
        let data = try loadFixtureData("gemini-quota-response-fixture.json")
        let response = try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        let buckets = try #require(response.buckets)
        #expect(buckets.count == 3)
        #expect(buckets[0].modelId == "gemini-2.5-pro")
        #expect(buckets[0].remainingFraction == 0.85)
        #expect(buckets[0].tokenType == "INPUT_TOKEN")
        #expect(buckets[0].remainingAmount == "850000")
        #expect(buckets[1].modelId == "gemini-2.5-flash")
        #expect(buckets[1].remainingFraction == 0.92)
        #expect(buckets[2].modelId == "gemini-2.5-flash-lite")
        #expect(buckets[2].remainingFraction == 0.98)
    }

    // MARK: - 2. resetTimeAsDate returns the expected epoch for 2026-05-16T00:00:00Z

    @Test func resetTimeAsDate_parsesPlainISO8601() throws {
        let data = try loadFixtureData("gemini-quota-response-fixture.json")
        let response = try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        let bucket = try #require(response.buckets?.first)
        let resetDate = try #require(bucket.resetTimeAsDate())
        // 2026-05-16T00:00:00Z = epoch 1778889600 (computed via `date -j -f`).
        let expected = Date(timeIntervalSince1970: 1_778_889_600)
        #expect(abs(resetDate.timeIntervalSince(expected)) < 0.001)
    }

    // MARK: - 3. resetTimeAsDate handles fractional seconds (Pitfall 3)

    @Test func resetTimeAsDate_parsesFractionalSeconds() throws {
        let bucket = GeminiQuotaResponse.Bucket(
            remainingFraction: 0.5,
            resetTime: "2026-05-16T00:00:00.123Z",
            modelId: "x",
            tokenType: "INPUT_TOKEN",
            remainingAmount: "1"
        )
        let resetDate = try #require(bucket.resetTimeAsDate())
        let expected = Date(timeIntervalSince1970: 1_778_889_600.123)
        #expect(abs(resetDate.timeIntervalSince(expected)) < 0.01)
    }

    // MARK: - 4. resetTimeAsDate returns nil when resetTime is nil

    @Test func resetTimeAsDate_returnsNilWhenAbsent() throws {
        let bucket = GeminiQuotaResponse.Bucket(
            remainingFraction: 0.5,
            resetTime: nil,
            modelId: "x",
            tokenType: nil,
            remainingAmount: nil
        )
        #expect(bucket.resetTimeAsDate() == nil)
    }

    // MARK: - 5. Empty `{}` decodes to buckets == nil

    @Test func decodes_emptyObjectAsNilBuckets() throws {
        let data = "{}".data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        #expect(response.buckets == nil)
    }

    // MARK: - 6. Unknown top-level field is tolerated

    @Test func decodes_withUnknownTopLevelField() throws {
        let json = """
        {
          "buckets": [],
          "unknownFutureField": { "foo": 1 }
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiQuotaResponse.self, from: json)
        let buckets = try #require(response.buckets)
        #expect(buckets.isEmpty)
    }

    // MARK: - 7. Multibucket fixture decodes both buckets for the same model

    @Test func decodes_multiBucketFixture_keepsBothEntries() throws {
        let data = try loadFixtureData("gemini-quota-response-multibucket-fixture.json")
        let response = try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        let buckets = try #require(response.buckets)
        #expect(buckets.count == 2)
        #expect(buckets[0].modelId == "gemini-2.5-pro")
        #expect(buckets[0].remainingFraction == 0.85)
        #expect(buckets[0].tokenType == "INPUT_TOKEN")
        #expect(buckets[1].modelId == "gemini-2.5-pro")
        #expect(buckets[1].remainingFraction == 0.60)
        #expect(buckets[1].tokenType == "OUTPUT_TOKEN")
    }
}

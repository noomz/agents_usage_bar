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

// MARK: - GeminiLoadCodeAssistResponseTests

@Suite("GeminiLoadCodeAssistResponseTests")
struct GeminiLoadCodeAssistResponseTests {

    // MARK: - 1. Happy path — String form of cloudaicompanionProject

    @Test func decodes_happyFixture_withStringProject() throws {
        let data = try loadFixtureData("gemini-loadcodeassist-fixture.json")
        let response = try JSONDecoder().decode(GeminiLoadCodeAssistResponse.self, from: data)
        #expect(response.currentTier?.id == "free-tier")
        #expect(response.currentTier?.name == "Free")
        #expect(response.currentTier?.hasAcceptedTos == true)
        #expect(response.cloudaicompanionProject == "gen-lang-client-0123456789")
    }

    // MARK: - 2. tierDisplayName mapping (RESEARCH correction #6)

    @Test func tierDisplayName_mapsKnownIDs() {
        #expect(GeminiLoadCodeAssistResponse.tierDisplayName(forID: "free-tier") == "Free")
        #expect(GeminiLoadCodeAssistResponse.tierDisplayName(forID: "legacy-tier") == "Legacy")
        #expect(GeminiLoadCodeAssistResponse.tierDisplayName(forID: "standard-tier") == "Paid")
        #expect(GeminiLoadCodeAssistResponse.tierDisplayName(forID: "future-tier-xyz") == "future-tier-xyz")
        #expect(GeminiLoadCodeAssistResponse.tierDisplayName(forID: nil) == nil)
    }

    // MARK: - 3. Object form of cloudaicompanionProject

    @Test func decodes_objectShapeProject_normalisesToString() throws {
        let data = try loadFixtureData("gemini-loadcodeassist-object-project-fixture.json")
        let response = try JSONDecoder().decode(GeminiLoadCodeAssistResponse.self, from: data)
        #expect(response.currentTier?.id == "standard-tier")
        // Either `id` or `projectId` (prefer `id`) — the normalised String must match.
        #expect(response.cloudaicompanionProject == "gen-lang-client-9999999999")
    }

    // MARK: - 4. Pitfall 8 cold-start — currentTier null

    @Test func decodes_coldStartFixture_currentTierNil() throws {
        let data = try loadFixtureData("gemini-loadcodeassist-coldstart-fixture.json")
        let response = try JSONDecoder().decode(GeminiLoadCodeAssistResponse.self, from: data)
        #expect(response.currentTier == nil)
        #expect(response.cloudaicompanionProject == nil)
        #expect(GeminiLoadCodeAssistResponse.tierDisplayName(forID: response.currentTier?.id) == nil)
    }

    // MARK: - 5. Lenient — unknown fields inside currentTier are tolerated

    @Test func decodes_unknownFieldsInsideCurrentTier() throws {
        let json = """
        {
          "currentTier": {
            "id": "free-tier",
            "name": "Free",
            "futureField": "future-value"
          },
          "cloudaicompanionProject": "p"
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiLoadCodeAssistResponse.self, from: json)
        #expect(response.currentTier?.id == "free-tier")
    }

    // MARK: - 6. cloudaicompanionProject absent

    @Test func decodes_withoutProjectField() throws {
        let json = """
        {
          "currentTier": { "id": "free-tier" }
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiLoadCodeAssistResponse.self, from: json)
        #expect(response.currentTier?.id == "free-tier")
        #expect(response.cloudaicompanionProject == nil)
    }

    // MARK: - 7. cloudaicompanionProject Object form with only `projectId`

    @Test func decodes_objectShapeProject_projectIdOnly() throws {
        let json = """
        {
          "currentTier": { "id": "free-tier" },
          "cloudaicompanionProject": { "projectId": "from-projectId-only" }
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiLoadCodeAssistResponse.self, from: json)
        #expect(response.cloudaicompanionProject == "from-projectId-only")
    }
}

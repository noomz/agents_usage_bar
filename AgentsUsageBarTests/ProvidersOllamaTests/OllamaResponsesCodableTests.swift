import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Fixture loading

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func loadFixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

// MARK: - OllamaResponsesCodableTests

@Suite("OllamaResponsesCodableTests")
struct OllamaResponsesCodableTests {

    // MARK: - OllamaPsResponse

    @Test func psResponse_decodesSingleModelFixture() throws {
        let data = try loadFixture("ollama-ps-single-model.json")
        let response = try JSONDecoder().decode(OllamaPsResponse.self, from: data)
        #expect(response.models?.count == 1)
        #expect(response.models?.first?.name == "llama3:8b")
        #expect(response.models?.first?.sizeVram == 5_137_025_024)
        #expect(response.models?.first?.details?.family == "llama")
        #expect(response.models?.first?.details?.parameterSize == "8.0B")
        #expect(response.models?.first?.details?.quantizationLevel == "Q4_0")
    }

    @Test func psResponse_decodesMultiModelFixture() throws {
        let data = try loadFixture("ollama-ps-multi-model.json")
        let response = try JSONDecoder().decode(OllamaPsResponse.self, from: data)
        #expect(response.models?.count == 3)
        #expect(response.models?.first?.name == "llama3:8b")
    }

    @Test func psResponse_decodesEmptyModels() throws {
        let data = try loadFixture("ollama-ps-empty.json")
        let response = try JSONDecoder().decode(OllamaPsResponse.self, from: data)
        #expect(response.models?.isEmpty == true)
    }

    /// Pitfall 7 — synthesised Decodable silently ignores unknown future fields.
    @Test func psResponse_tolerantOfUnknownFutureField() throws {
        let json = #"{"models":[{"name":"x","size_vram":100,"future_field_2027":"foo"}]}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(OllamaPsResponse.self, from: data)
        #expect(response.models?.count == 1)
        #expect(response.models?.first?.name == "x")
        #expect(response.models?.first?.sizeVram == 100)
    }

    /// OQ-4 — CPU-only model: `size_vram` absent → `nil` (not a decode error).
    @Test func psResponse_tolerantOfMissingSizeVram() throws {
        let json = #"{"models":[{"name":"cpu-only"}]}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(OllamaPsResponse.self, from: data)
        #expect(response.models?.count == 1)
        #expect(response.models?.first?.sizeVram == nil)
    }

    /// Absent `details` object decodes as `nil`.
    @Test func psResponse_tolerantOfMissingDetails() throws {
        let json = #"{"models":[{"name":"cpu-only"}]}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(OllamaPsResponse.self, from: data)
        #expect(response.models?.first?.details == nil)
    }

    /// Pitfall 11 invariant — `sizeVram` must be `Int64`, not `Int`.
    /// Verify the property type annotation at compile time via a large value.
    @Test func psResponse_sizeVramIsInt64_handlesLargeValue() throws {
        // 70B Q5_K_M ~50 GB in bytes (exceeds Int32.max = 2_147_483_647)
        let bigVram: Int64 = 53_687_091_200
        let json = "{\"models\":[{\"name\":\"llama-70b\",\"size_vram\":\(bigVram)}]}"
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(OllamaPsResponse.self, from: data)
        #expect(response.models?.first?.sizeVram == bigVram)
    }

    // MARK: - OllamaTagsResponse

    @Test func tagsResponse_decodesNonEmptyFixture() throws {
        let data = try loadFixture("ollama-tags-non-empty.json")
        let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        #expect(response.models?.count == 2)
        #expect(response.models?.first?.name == "codellama:13b")
    }

    @Test func tagsResponse_decodesEmptyFixture() throws {
        let data = try loadFixture("ollama-tags-empty.json")
        let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        #expect(response.models?.isEmpty == true)
    }

    /// Only `name` is required; any extra fields (modified_at, size, etc.) silently ignored.
    @Test func tagsResponse_tolerantOfMissingFields() throws {
        let json = #"{"models":[{"name":"llama3:8b","modified_at":"2026-01-01","size":999}]}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        #expect(response.models?.count == 1)
        #expect(response.models?.first?.name == "llama3:8b")
    }

    /// Top-level unknown fields don't throw.
    @Test func tagsResponse_tolerantOfTopLevelUnknownField() throws {
        let json = #"{"models":[{"name":"x"}],"new_field":42}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        #expect(response.models?.count == 1)
    }

    // MARK: - LOCAL-06 negative invariant (source-level static guard)

    /// LOCAL-06 anti-feature: OllamaPsResponse must never reference token/cost fields.
    @Test func noTokenFieldInPsResponseSource() throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentsUsageBar/Providers/Ollama/Models/OllamaPsResponse.swift")
        let source = try String(contentsOf: sourceFile, encoding: .utf8)
        #expect(!source.contains("tokensToday"))
        #expect(!source.contains("tokenCount"))
        #expect(!source.contains("costTodayUSD"))
    }
}

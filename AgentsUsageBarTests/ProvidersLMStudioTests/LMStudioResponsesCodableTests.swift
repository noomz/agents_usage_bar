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

private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

// MARK: - LMStudioResponsesCodableTests

@Suite("LMStudioResponsesCodableTests")
struct LMStudioResponsesCodableTests {

    // MARK: - LMStudioV0ModelsResponse

    @Test func v0Response_decodesMixedStateFixture() throws {
        let data = try fixtureData("lmstudio-v0-models-mixed-state.json")
        let response = try JSONDecoder().decode(LMStudioV0ModelsResponse.self, from: data)
        #expect(response.data?.count == 2)
        #expect(response.object == "list")
    }

    @Test func v0Response_loadedModelsHelperFiltersByState() throws {
        let data = try fixtureData("lmstudio-v0-models-mixed-state.json")
        let response = try JSONDecoder().decode(LMStudioV0ModelsResponse.self, from: data)
        // mixed-state: qwen2-vl-7b is not-loaded, meta-llama-3.1-8b is loaded
        let loaded = response.loadedModels
        #expect(loaded.count == 1)
        #expect(loaded[0].id == "meta-llama-3.1-8b")
    }

    @Test func v0Response_loadedModelsTreatsNilStateAsLoaded() throws {
        // Fixture with absent state field — old-build behavior per RESEARCH §2.2
        let json = #"{"object":"list","data":[{"id":"old-model-no-state"}]}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(LMStudioV0ModelsResponse.self, from: data)
        // state is nil — loadedModels should include it (treated as loaded by default)
        let loaded = response.loadedModels
        #expect(loaded.count == 1)
        #expect(loaded[0].id == "old-model-no-state")
        #expect(loaded[0].state == nil)
    }

    @Test func v0Response_tolerantOfUnknownFutureField() throws {
        // Adding an unknown field that doesn't exist in 2026 — must decode without error
        let json = #"{"object":"list","future_field_2027":42,"data":[{"id":"x","state":"loaded","future_model_field":true}]}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(LMStudioV0ModelsResponse.self, from: data)
        #expect(response.data?.count == 1)
        #expect(response.data?[0].id == "x")
    }

    @Test func v0Response_allLoadedFixture_bothModelsLoaded() throws {
        let data = try fixtureData("lmstudio-v0-models-all-loaded.json")
        let response = try JSONDecoder().decode(LMStudioV0ModelsResponse.self, from: data)
        #expect(response.data?.count == 2)
        let loaded = response.loadedModels
        #expect(loaded.count == 2)
        // Verify explicit fields decoded
        #expect(loaded[0].arch == "llama")
        #expect(loaded[0].quantization == "Q4_K_M")
        #expect(loaded[0].loadedContextLength == 4096)
    }

    @Test func v0Response_noneLoadedFixture_zeroLoadedModels() throws {
        let data = try fixtureData("lmstudio-v0-models-none-loaded.json")
        let response = try JSONDecoder().decode(LMStudioV0ModelsResponse.self, from: data)
        #expect(response.data?.count == 2)
        #expect(response.loadedModels.isEmpty)
    }

    @Test func v0Response_snakeCaseCodingKey_loadedContextLength() throws {
        // Explicit snake_case CodingKey — Phase 3 STATE #67
        let json = #"{"data":[{"id":"m","loaded_context_length":8192}]}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(LMStudioV0ModelsResponse.self, from: data)
        #expect(response.data?[0].loadedContextLength == 8192)
    }

    // MARK: - LMStudioV1ModelsResponse

    @Test func v1Response_decodesFallbackFixture() throws {
        let data = try fixtureData("lmstudio-v1-models-fallback.json")
        let response = try JSONDecoder().decode(LMStudioV1ModelsResponse.self, from: data)
        #expect(response.data?.count == 1)
        #expect(response.data?[0].id == "meta-llama-3.1-8b")
    }

    @Test func v1Response_tolerantOfMinimalShape() throws {
        // Minimal shape — missing `object` and `owned_by`
        let json = #"{"data":[{"id":"x"}]}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(LMStudioV1ModelsResponse.self, from: data)
        #expect(response.object == nil)
        #expect(response.data?.count == 1)
        #expect(response.data?[0].id == "x")
    }

    @Test func v1Response_emptyData() throws {
        let json = #"{"object":"list","data":[]}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(LMStudioV1ModelsResponse.self, from: data)
        #expect(response.data?.isEmpty == true)
    }

    @Test func v1Response_tolerantOfUnknownFutureField() throws {
        let json = #"{"object":"list","data":[{"id":"y","owned_by":"org","future_field":99}],"extra_top":true}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(LMStudioV1ModelsResponse.self, from: data)
        #expect(response.data?[0].id == "y")
    }

    // MARK: - LOCAL-06 negative invariant

    @Test func noTokenFieldInModelFiles() throws {
        // LOCAL-06: model source files must not contain token/cost references.
        let baseURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentsUsageBar/Providers/LMStudio/Models")

        let v0Source = try String(
            contentsOf: baseURL.appendingPathComponent("LMStudioV0ModelsResponse.swift"),
            encoding: .utf8
        )
        let v1Source = try String(
            contentsOf: baseURL.appendingPathComponent("LMStudioV1ModelsResponse.swift"),
            encoding: .utf8
        )
        let combined = v0Source + v1Source
        // Check for actual code patterns (not doc comment mentions) — same technique as 04-04 SUMMARY.
        // Doc comments may mention "AnyCodable" negatively ("no AnyCodable plumbing needed") — safe.
        #expect(!combined.contains("tokensToday:"))
        #expect(!combined.contains("tokenCount:"))
        #expect(!combined.contains("costTodayUSD:"))
        // AnyCodable must not be used as a type (i.e. not appear as a Swift type annotation or init)
        #expect(!combined.contains("AnyCodable("))
        #expect(!combined.contains(": AnyCodable"))
        #expect(!combined.contains("extraFields:"))
    }
}

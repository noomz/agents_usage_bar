import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Fixture loading

private func llamaCppFixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func llamaCppFixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: llamaCppFixtureURL(name))
}

// MARK: - LlamaCppResponsesCodableTests

@Suite("LlamaCppResponsesCodableTests")
struct LlamaCppResponsesCodableTests {

    // MARK: - LlamaCppHealthResponse — fixture decoding

    @Test func health_okFixture_isOKTrue() throws {
        let data = try llamaCppFixtureData("llamacpp-health-ok.json")
        let response = try JSONDecoder().decode(LlamaCppHealthResponse.self, from: data)
        #expect(response.status == "ok")
        #expect(response.isOK == true)
        #expect(response.isLoading == false)
        #expect(response.isErrorStatus == false)
        #expect(response.hasNoSlot == false)
        #expect(response.slotsIdle == 4)
        #expect(response.slotsProcessing == 0)
    }

    @Test func health_loadingFixture_isLoadingTrue() throws {
        let data = try llamaCppFixtureData("llamacpp-health-loading.json")
        let response = try JSONDecoder().decode(LlamaCppHealthResponse.self, from: data)
        #expect(response.status == "loading model")
        #expect(response.isLoading == true)
        #expect(response.isOK == false)
        #expect(response.isErrorStatus == false)
        #expect(response.hasNoSlot == false)
    }

    @Test func health_errorFixture_isErrorTrue() throws {
        let data = try llamaCppFixtureData("llamacpp-health-error.json")
        let response = try JSONDecoder().decode(LlamaCppHealthResponse.self, from: data)
        #expect(response.status == "error")
        #expect(response.isErrorStatus == true)
        #expect(response.isOK == false)
        #expect(response.isLoading == false)
    }

    @Test func health_noSlotFixture_hasNoSlotTrue() throws {
        let data = try llamaCppFixtureData("llamacpp-health-no-slot.json")
        let response = try JSONDecoder().decode(LlamaCppHealthResponse.self, from: data)
        #expect(response.status == "no slot available")
        #expect(response.hasNoSlot == true)
        #expect(response.isOK == false)
        #expect(response.slotsIdle == 0)
        #expect(response.slotsProcessing == 4)
    }

    @Test func health_nilStatusDecodesAsOK() throws {
        // Empty JSON object → status == nil; isOK must be true (OQ-3 nil-tolerant).
        let json = #"{}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(LlamaCppHealthResponse.self, from: data)
        #expect(response.status == nil)
        #expect(response.isOK == true)
        #expect(response.isLoading == false)
        #expect(response.isErrorStatus == false)
    }

    @Test func health_unknownFutureStatusDecodes() throws {
        // OQ-3: unknown status decodes without throwing; none of the four discriminators fire.
        let json = #"{"status":"future-shape-2027"}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(LlamaCppHealthResponse.self, from: data)
        #expect(response.status == "future-shape-2027")
        #expect(response.isOK == false)
        #expect(response.isLoading == false)
        #expect(response.isErrorStatus == false)
        #expect(response.hasNoSlot == false)
    }

    @Test func health_tolerantOfUnknownFields() throws {
        // Pitfall 7: unknown future fields must not cause a decode failure.
        let json = #"{"status":"ok","slots_idle":2,"slots_processing":0,"future_field":1}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(LlamaCppHealthResponse.self, from: data)
        #expect(response.isOK == true)
    }

    // MARK: - LlamaCppV1ModelsResponse

    @Test func v1Models_decodesAndExtractsBasename() throws {
        let data = try llamaCppFixtureData("llamacpp-v1-models.json")
        let response = try JSONDecoder().decode(LlamaCppV1ModelsResponse.self, from: data)
        #expect(response.object == "list")
        #expect(response.data?.count == 1)
        // modelBasename must be the filename only, NOT the full path.
        #expect(response.modelBasename == "llama-3-8b-instruct-Q4_K_M.gguf")
    }

    @Test func v1Models_emptyData() throws {
        let json = #"{"object":"list","data":[]}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(LlamaCppV1ModelsResponse.self, from: data)
        #expect(response.data?.isEmpty == true)
        #expect(response.modelBasename == nil)
    }

    @Test func v1Models_tolerantOfUnknownFields() throws {
        // Pitfall 7: extra fields in model objects must not throw.
        let json = #"{"object":"list","data":[{"id":"/foo/bar/baz.gguf","unknown_field":"hello"}]}"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(LlamaCppV1ModelsResponse.self, from: data)
        #expect(response.modelBasename == "baz.gguf")
    }

    // MARK: - LlamaCppSlotsResponse

    @Test func slots_decodesArrayShape() throws {
        let data = try llamaCppFixtureData("llamacpp-slots.json")
        let response = try JSONDecoder().decode(LlamaCppSlotsResponse.self, from: data)
        #expect(response.slots.count == 1)
        #expect(response.slots[0].id == 0)
        #expect(response.slots[0].state == "idle")
    }

    @Test func slots_tolerantOfMissingFields() throws {
        // [{}] — empty slot object decodes; id and state are nil.
        let json = #"[{}]"#
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(LlamaCppSlotsResponse.self, from: data)
        #expect(response.slots.count == 1)
        #expect(response.slots[0].id == nil)
        #expect(response.slots[0].state == nil)
    }
}

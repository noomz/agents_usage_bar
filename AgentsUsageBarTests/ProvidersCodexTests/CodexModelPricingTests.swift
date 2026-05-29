import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Fixture loading helpers

/// Loads the deterministic 7-model pricing fixture using `#filePath` resolution,
/// mirroring the ClaudeModelPricingTests pattern (no `Bundle.module` / Copy Bundle Resources needed).
private func loadFixturePricing() throws -> CodexModelPricing {
    let thisFile = URL(fileURLWithPath: #filePath)
    let fixtureURL = thisFile
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("codex-models-fixture.json")
    return try CodexModelPricing.load(from: fixtureURL)
}

// MARK: - Decimal comparison helper (STATE #28 precedent)

/// Converts a Decimal to Double via NSDecimalNumber and checks within tolerance.
/// Mirrors Phase 2 D-28 monetary comparison idiom.
private func decimalsClose(_ a: Decimal, _ b: Double, tolerance: Double = 1e-6) -> Bool {
    let aDouble = NSDecimalNumber(decimal: a).doubleValue
    return abs(aDouble - b) <= tolerance
}

// MARK: - Test Suite

@Suite("CodexModelPricing")
struct CodexModelPricingTests {

    // MARK: 1. Decode round-trip — schemaVersion + sample fields
    @Test("loadFromFixture decodes schemaVersion + default + key model fields")
    func loadFromFixture_decodesAllFields() throws {
        let pricing = try loadFixturePricing()
        #expect(pricing.schemaVersion == 1)
        #expect(pricing.`default`.inputPerMToken == 0.750)
        #expect(pricing.`default`.outputPerMToken == 3.000)
        #expect(pricing.`default`.cachedInputPerMToken == 0.025)
        #expect(pricing.models["codex-mini-latest"]?.outputPerMToken == 3.000)
        #expect(pricing.models["o4-mini"]?.cachedInputPerMToken == 0.275)
        #expect(pricing.models.count == 7)
    }

    // MARK: 2. Exact match for codex-mini-latest
    @Test("rate(for: codex-mini-latest) returns exact source")
    func rate_exactMatch_codexMiniLatest() throws {
        let pricing = try loadFixturePricing()
        let (rate, source) = pricing.rate(for: "codex-mini-latest")
        #expect(source == .exact)
        #expect(rate == pricing.models["codex-mini-latest"])
    }

    // MARK: 3. Unknown model → defaultFallback
    @Test("rate(for: totally-unknown-codex-model) falls back to default")
    func rate_unknownModel_fallsBackToDefault() throws {
        let pricing = try loadFixturePricing()
        let (rate, source) = pricing.rate(for: "totally-unknown-codex-model")
        #expect(source == .defaultFallback)
        #expect(rate == pricing.`default`)
    }

    // MARK: 4. nil model → nilModel source
    @Test("rate(for: nil) returns default rate with nilModel source")
    func rate_nilModel_returnsDefault() throws {
        let pricing = try loadFixturePricing()
        let (rate, source) = pricing.rate(for: nil)
        #expect(source == .nilModel)
        #expect(rate == pricing.`default`)
    }

    // MARK: 5. cost(1M input only, codex-mini-latest) ≈ $0.75
    @Test("cost with 1M input tokens at codex-mini-latest is $0.75")
    func cost_oneMillionInputOnly_codexMiniLatest() throws {
        let pricing = try loadFixturePricing()
        let cost = pricing.cost(
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            modelID: "codex-mini-latest"
        )
        #expect(decimalsClose(cost, 0.75, tolerance: 1e-9))
    }

    // MARK: 6. cost(1M input, 500K cached) confirms (input - cached) billed at input rate
    // (1_000_000 - 500_000) * 0.75 / 1e6  +  500_000 * 0.025 / 1e6
    // = 500_000 * 0.75e-6 + 500_000 * 0.025e-6
    // = 0.375 + 0.0125 = 0.3875
    @Test("cost with 1M input + 500K cached at codex-mini-latest is $0.3875")
    func cost_inputMinusCachedAtInputRate_cachedAtCachedRate() throws {
        let pricing = try loadFixturePricing()
        let cost = pricing.cost(
            inputTokens: 1_000_000,
            cachedInputTokens: 500_000,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            modelID: "codex-mini-latest"
        )
        #expect(decimalsClose(cost, 0.3875, tolerance: 1e-9))
    }

    // MARK: 7. reasoning_output_tokens is NOT double-counted
    @Test("reasoningOutputTokens does not alter cost (already counted inside outputTokens)")
    func cost_reasoningOutputTokens_notDoubleCounted() throws {
        let pricing = try loadFixturePricing()
        let withReasoning = pricing.cost(
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 1_000_000,
            reasoningOutputTokens: 500_000,
            modelID: nil
        )
        let withoutReasoning = pricing.cost(
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 1_000_000,
            reasoningOutputTokens: 0,
            modelID: nil
        )
        #expect(withReasoning == withoutReasoning)
    }

    // MARK: 8. RESEARCH 2026 fixture event totals — hand-computed USD
    // input=551589, cached=505856, output=4880, reasoning=620 (ignored), modelID=nil → default rate
    // (551589 - 505856) * 0.75 / 1e6 + 505856 * 0.025 / 1e6 + 4880 * 3.00 / 1e6
    // = 0.03429975 + 0.012646400 + 0.01464
    // = 0.061586150
    @Test("2026 RESEARCH fixture event totals at default rate yields $0.061586")
    func cost_research2026FixtureTotals_defaultRate() throws {
        let pricing = try loadFixturePricing()
        let cost = pricing.cost(
            inputTokens: 551_589,
            cachedInputTokens: 505_856,
            outputTokens: 4_880,
            reasoningOutputTokens: 620,
            modelID: nil
        )
        #expect(decimalsClose(cost, 0.061586, tolerance: 1e-6))
    }

    // MARK: 9. Load failure — non-existent file URL throws decodeFailed
    @Test("load(from: missing URL) throws decodeFailed")
    func loadFromMissingURL_throwsDecodeFailed() {
        let badURL = URL(fileURLWithPath: "/tmp/codex-models-does-not-exist-\(UUID().uuidString).json")
        #expect(throws: CodexModelPricingError.self) {
            _ = try CodexModelPricing.load(from: badURL)
        }
    }

    // MARK: 10. CR-01 — cross-column arithmetic stays in Decimal
    // Locks the contract that each rate column is multiplied + divided in
    // Decimal independently. Summing the three contributions as Decimal must
    // equal the cost(...) result exactly; any Double-accumulation regression
    // would diverge at the integer-rate / huge-token boundary chosen below.
    @Test("cost(...) matches component-wise Decimal sum (CR-01 regression)")
    func cost_matchesComponentwiseDecimalSum_noDoubleAccumulation() throws {
        // Rates chosen so Double arithmetic would round each column differently
        // and the cross-column sum would drift from the per-column Decimal sum.
        let rate = CodexModelPricing.Rate(
            inputPerMToken: 1.2345678,
            outputPerMToken: 9.8765432,
            cachedInputPerMToken: 0.0123456
        )
        let pricing = CodexModelPricing(
            schemaVersion: 1,
            lastUpdated: "2026-05-18",
            default: rate,
            models: [:]
        )

        // High token counts amplify any cross-column Double drift.
        let nonCached = 7_654_321
        let cached = 2_345_678
        let output = 3_210_987
        let actual = pricing.cost(
            inputTokens: nonCached + cached,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningOutputTokens: 0,
            modelID: nil
        )

        let perMillion = Decimal(1_000_000)
        let expected =
            (Decimal(nonCached) * Decimal(rate.inputPerMToken)) / perMillion
            + (Decimal(cached) * Decimal(rate.cachedInputPerMToken)) / perMillion
            + (Decimal(output) * Decimal(rate.outputPerMToken)) / perMillion
        #expect(actual == expected)
    }
}

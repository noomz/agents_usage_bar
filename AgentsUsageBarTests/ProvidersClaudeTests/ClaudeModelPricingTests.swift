import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Fixture loading helper

/// Loads the deterministic 3-entry pricing fixture using #filePath resolution,
/// mirroring the TranscriptRecordTests pattern (no Bundle.module / Copy Bundle Resources needed).
private func loadFixturePricing() throws -> ClaudeModelPricing {
    let thisFile = URL(fileURLWithPath: #filePath)
    let fixtureURL = thisFile
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("pricing-test-models.json")
    return try ClaudeModelPricing.load(from: fixtureURL)
}

/// Helper to load the production claude-models.json directly from the repo tree
/// (avoids needing Bundle.main in test context; mirrors Plan 01.04 / W7 pattern).
private func loadProductionPricing() throws -> ClaudeModelPricing {
    let thisFile = URL(fileURLWithPath: #filePath)
    // Navigate up: ClaudeModelPricingTests.swift → ProvidersClaudeTests → AgentsUsageBarTests → repo root
    let repoRoot = thisFile
        .deletingLastPathComponent()   // ProvidersClaudeTests
        .deletingLastPathComponent()   // AgentsUsageBarTests
        .deletingLastPathComponent()   // repo root
    let productionURL = repoRoot
        .appendingPathComponent("AgentsUsageBar")
        .appendingPathComponent("Resources")
        .appendingPathComponent("Pricing")
        .appendingPathComponent("claude-models.json")
    return try ClaudeModelPricing.load(from: productionURL)
}

// MARK: - Decimal comparison helper (D-28 precedent)

/// Converts a Decimal to Double via NSDecimalNumber and checks within tolerance.
/// Mirrors Phase 1 D-28 approach for monetary comparison in tests.
private func decimalsClose(_ a: Decimal, _ b: Double, tolerance: Double = 0.001) -> Bool {
    let aDouble = NSDecimalNumber(decimal: a).doubleValue
    return abs(aDouble - b) <= tolerance
}

// MARK: - Test Suite

@Suite("ClaudeModelPricing")
struct ClaudeModelPricingTests {

    // MARK: 1. loadBundled — app-hosted tests use AgentsUsageBar.app as Bundle.main,
    //          which ships claude-models.json. Assert the production path succeeds
    //          and surfaces real pricing entries (T-02.02-03: load path is reachable).
    @Test("loadBundled succeeds when running in app-hosted test target")
    func loadBundled_succeedsInAppHostedTestTarget() throws {
        // Test target hosts in AgentsUsageBar.app, so Bundle.main is the app bundle and
        // claude-models.json is shipped there. The graceful error path is exercised
        // separately by tests that point ClaudeModelPricing.load(from:) at a missing URL.
        let pricing = try ClaudeModelPricing.loadBundled()
        #expect(!pricing.models.isEmpty)
    }

    // MARK: 2. Fixture decode
    @Test("loadFromFixture decodes all expected fields")
    func loadFromFixture_decodesAllFields() throws {
        let pricing = try loadFixturePricing()
        #expect(pricing.schemaVersion == 1)
        #expect(pricing.lastUpdated == "2026-01-01")
        #expect(pricing.`default`.inputPer1M == 2.00)
        #expect(pricing.`default`.outputPer1M == 10.00)
        #expect(pricing.`default`.cacheWritePer1M == 2.50)
        #expect(pricing.`default`.cacheReadPer1M == 0.20)
        #expect(pricing.models.count == 3)
    }

    // MARK: 3. nil model → nilModel source
    @Test("rate(for: nil) returns default rate with nilModel source")
    func rate_nilModel_returnsDefault() throws {
        let pricing = try loadFixturePricing()
        let (rate, source) = pricing.rate(for: nil)
        #expect(source == .nilModel)
        #expect(rate.inputPer1M == pricing.`default`.inputPer1M)
    }

    // MARK: 4. Empty string → nilModel source
    @Test("rate(for: empty string) returns default rate with nilModel source")
    func rate_emptyString_returnsNilModel() throws {
        let pricing = try loadFixturePricing()
        let (_, source) = pricing.rate(for: "")
        #expect(source == .nilModel)
    }

    // MARK: 5. Exact match
    @Test("rate(for: exact model ID) returns exact source")
    func rate_exactMatch_wins() throws {
        let pricing = try loadFixturePricing()
        let (rate, source) = pricing.rate(for: "test-model-exact")
        #expect(source == .exact)
        #expect(rate.inputPer1M == 1.00)
        #expect(rate.outputPer1M == 5.00)
    }

    // MARK: 6. Prefix match — model ID longer than key
    @Test("rate(for: longer ID with known prefix) returns prefix source")
    func rate_prefixMatch_modelIDLonger() throws {
        let pricing = try loadFixturePricing()
        let (rate, source) = pricing.rate(for: "test-model-prefix-extended-id")
        if case .prefix(let matched) = source {
            #expect(matched == "test-model-prefix")
        } else {
            Issue.record("Expected .prefix source, got \(source)")
        }
        #expect(rate.inputPer1M == 4.00)
    }

    // MARK: 7. Heuristic match — opus family
    @Test("rate(for: future opus model) returns heuristic opus source")
    func rate_heuristicMatch_opus() throws {
        let pricing = try loadFixturePricing()
        let (rate, source) = pricing.rate(for: "claude-opus-future")
        if case .heuristic(let family) = source {
            #expect(family == "opus")
        } else {
            Issue.record("Expected .heuristic(family: \"opus\") source, got \(source)")
        }
        // claude-opus-test is the only opus entry in the fixture (inputPer1M = 15.00)
        #expect(rate.inputPer1M == 15.00)
        #expect(rate.outputPer1M == 75.00)
    }

    // MARK: 8. Unknown model → defaultFallback
    @Test("rate(for: completely unknown model) falls back to default")
    func rate_unknownModel_fallsBackToDefault() throws {
        let pricing = try loadFixturePricing()
        let (rate, source) = pricing.rate(for: "completely-unknown-xyz")
        #expect(source == .defaultFallback)
        #expect(rate.inputPer1M == pricing.`default`.inputPer1M)
    }

    // MARK: 9. Cost — 1M tokens across all four fields for test-model-exact
    // test-model-exact: input=1.00, output=5.00, cacheWrite=1.25, cacheRead=0.10
    // 1M each → cost = 1.00 + 5.00 + 1.25 + 0.10 = $7.35
    @Test("cost with 1M tokens across all four fields for exact model is $7.35")
    func cost_oneMillionEachFourFields_exactModel() throws {
        let pricing = try loadFixturePricing()
        let cost = pricing.cost(
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheCreationTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            modelID: "test-model-exact"
        )
        #expect(decimalsClose(cost, 7.35))
    }

    // MARK: 10. cache_read = 0.10× input verified via cost
    // test-model-exact: input=1.00/1M, cacheRead=0.10/1M
    // 10M input tokens → $10.00; 100M cacheRead tokens → $10.00 (same cost)
    @Test("cache read cost is 0.10× input cost for exact model")
    func cost_cacheReadIsTenPercentOfInput() throws {
        let pricing = try loadFixturePricing()
        let inputOnly = pricing.cost(
            inputTokens: 10_000_000,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            modelID: "test-model-exact"
        )
        let cacheReadOnly = pricing.cost(
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 100_000_000,
            modelID: "test-model-exact"
        )
        #expect(decimalsClose(inputOnly, 10.00))
        #expect(decimalsClose(cacheReadOnly, 10.00))
    }

    // MARK: 11. Unknown model uses default rate
    @Test("cost for unknown model uses default rate")
    func cost_unknownModel_appliesDefaultRate() throws {
        let pricing = try loadFixturePricing()
        // default.inputPer1M = 2.00 → 1M input tokens = $2.00
        let cost = pricing.cost(
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            modelID: "xyz-unknown-model"
        )
        #expect(decimalsClose(cost, 2.00))
    }

    // MARK: 12. Zero tokens → zero cost
    @Test("cost with zero tokens returns zero")
    func cost_zeroTokens_returnsZero() throws {
        let pricing = try loadFixturePricing()
        let cost = pricing.cost(
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            modelID: "test-model-exact"
        )
        #expect(cost == Decimal(0))
    }

    // MARK: 13. Production JSON cache-read = 0.10× input invariant for all 7 shipped models
    @Test("bundled JSON cache_read = 0.10× input for all 7 shipped Claude models")
    func bundledJSON_cacheReadRatio_holdsForAllShippedModels() throws {
        let pricing = try loadProductionPricing()
        #expect(pricing.models.count == 7)
        for (modelID, rate) in pricing.models {
            let expected = rate.inputPer1M * 0.10
            let actual = rate.cacheReadPer1M
            let diff = abs(actual - expected)
            #expect(diff <= 0.005, "Model \(modelID): cacheReadPer1M \(actual) ≠ 0.10× inputPer1M \(rate.inputPer1M) (diff=\(diff))")
        }
    }
}

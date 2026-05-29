import Foundation

// MARK: - Error

public enum CodexModelPricingError: Error, Sendable {
    case bundleResourceMissing
    case decodeFailed(Error)
}

// MARK: - Main struct

/// Bundled USD pricing table for Codex-capable OpenAI models.
///
/// Mirrors `ClaudeModelPricing` (Phase 2 D-08 / Plan 02-02) but specialised for the
/// Codex rollout schema:
///
///   * The Codex rollout `token_count` event reports `input_tokens`,
///     `cached_input_tokens`, `output_tokens`, and `reasoning_output_tokens` —
///     where `reasoning_output_tokens` is a SUBSET of `output_tokens` and is
///     billed at the same output rate. The `cost(...)` calculator therefore
///     accepts `reasoningOutputTokens` as a documentary parameter and DOES NOT
///     fold it into the math (see RESEARCH §"Embedded Pricing" / Pitfall 11).
///   * No `cache_write` notion exists in Codex pricing; only cached READS are
///     priced separately. The `Rate` shape collapses to
///     `inputPerMToken / outputPerMToken / cachedInputPerMToken`.
///   * Cascade lookup is `exact -> defaultFallback` only — there are no model
///     families (no opus/sonnet/haiku analog for OpenAI Codex). The rollout
///     does not currently expose a model ID in the `token_count` event, so
///     the `default` entry is what every cost calculation uses today.
///
/// Loaded from `codex-models.json` shipped in the app bundle.
///
/// THREAT NOTE (T-03.02-02 / T-03.02-03): No `os.Logger` calls in this file.
/// Pricing values are public information; the discipline keeps logging surface
/// minimal and matches the Phase 2 `ClaudeModelPricing` stance.
public struct CodexModelPricing: Decodable, Sendable {

    // MARK: - Rate

    public struct Rate: Decodable, Sendable, Equatable {
        public let inputPerMToken: Double
        public let outputPerMToken: Double
        public let cachedInputPerMToken: Double

        public init(inputPerMToken: Double, outputPerMToken: Double, cachedInputPerMToken: Double) {
            self.inputPerMToken = inputPerMToken
            self.outputPerMToken = outputPerMToken
            self.cachedInputPerMToken = cachedInputPerMToken
        }
    }

    // MARK: - LookupSource

    public enum LookupSource: Sendable, Equatable {
        case exact
        case defaultFallback
        case nilModel
    }

    // MARK: - Stored properties

    public let schemaVersion: Int
    public let lastUpdated: String       // ISO date string, e.g. "2026-05-15"

    // NOTE: `default` is a Swift keyword. Backtick escaping is required here.
    // The JSON key is "default" and maps directly via Decodable synthesis.
    public let `default`: Rate

    public let models: [String: Rate]

    // MARK: - Init (for testing / preview)

    public init(schemaVersion: Int, lastUpdated: String, default defaultRate: Rate, models: [String: Rate]) {
        self.schemaVersion = schemaVersion
        self.lastUpdated = lastUpdated
        self.`default` = defaultRate
        self.models = models
    }

    // MARK: - Decodable coding keys

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case lastUpdated
        case `default`
        case models
        // `source` is documentary-only in JSON; JSONDecoder ignores unknown keys by default.
    }

    // MARK: - Loading

    /// Loads the bundled pricing table from the app's main bundle.
    ///
    /// Throws `CodexModelPricingError.bundleResourceMissing` when the resource is absent
    /// (e.g. running in unit-test context where Bundle.main is the test runner without
    /// the app host). Callers (Plan 03-04 / `CodexJSONLProvider`) catch this and degrade
    /// to a "pricing unavailable" placeholder rather than crashing — satisfies T-03.02-03.
    public static func loadBundled() throws -> CodexModelPricing {
        guard let url = Bundle.main.url(forResource: "codex-models", withExtension: "json") else {
            throw CodexModelPricingError.bundleResourceMissing
        }
        return try load(from: url)
    }

    /// Loads pricing from an arbitrary URL. Used by tests (fixture path) and previews.
    public static func load(from url: URL) throws -> CodexModelPricing {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            // keyDecodingStrategy is left at the default. Our JSON already uses
            // camelCase keys (inputPerMToken etc.). No snake-case conversion needed.
            return try decoder.decode(CodexModelPricing.self, from: data)
        } catch let error as CodexModelPricingError {
            throw error
        } catch {
            throw CodexModelPricingError.decodeFailed(error)
        }
    }

    // MARK: - Cascade lookup

    /// Returns the rate for `modelID` and the source that produced it.
    ///
    /// Cascade order (Codex-specialised, simpler than Claude):
    /// 1. nil / empty modelID  -> file-level `default`, source `.nilModel`.
    /// 2. Exact match on model ID key in `models`.
    /// 3. File-level `default`, source `.defaultFallback`.
    ///
    /// Deliberately NO prefix/family heuristic — Codex model IDs do not share a
    /// stable family prefix (codex-mini, o4-mini, o3, gpt-4.1 are not in one
    /// family) and the rollout does not surface model IDs in the `token_count`
    /// event today anyway, so the `default` path is the hot path.
    public func rate(for modelID: String?) -> (rate: Rate, source: LookupSource) {
        guard let modelID, !modelID.isEmpty else {
            return (`default`, .nilModel)
        }

        if let r = models[modelID] {
            return (r, .exact)
        }

        return (`default`, .defaultFallback)
    }

    // MARK: - Cost calculator

    /// Computes the USD cost for a single Codex rollout `token_count` event using `Decimal` arithmetic.
    ///
    /// Formula (RESEARCH §"Embedded Pricing"):
    /// ```
    /// cost = (inputTokens - cachedInputTokens) * (inputPerMToken / 1_000_000)
    ///      + cachedInputTokens                 * (cachedInputPerMToken / 1_000_000)
    ///      + outputTokens                      * (outputPerMToken / 1_000_000)
    /// ```
    ///
    /// **`reasoningOutputTokens` is INTENTIONALLY IGNORED in the math.** The Codex
    /// rollout schema documents `reasoning_output_tokens` as a *subset* of
    /// `output_tokens` — counting it again would double-bill. The parameter is
    /// preserved on the signature so that a future schema split (where reasoning
    /// would be billed separately, or excluded from `output_tokens`) is a
    /// one-line change rather than an API break for every caller.
    ///
    /// Uses `Decimal` at the final step per STATE #28 — avoids IEEE 754 drift on
    /// small monetary values that accumulate across thousands of rollout events.
    ///
    /// - Parameters:
    ///   - inputTokens: Raw `input_tokens` from `event.payload.info.total_token_usage`.
    ///   - cachedInputTokens: `cached_input_tokens` (subset of `inputTokens`).
    ///   - outputTokens: Raw `output_tokens` (includes reasoning_output_tokens).
    ///   - reasoningOutputTokens: `reasoning_output_tokens` — INFORMATIONAL; not added to cost.
    ///   - modelID: Codex model ID from `session_meta.model` if known (nil today).
    /// - Returns: USD cost as `Decimal`.
    public func cost(
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int,
        modelID: String?
    ) -> Decimal {
        // reasoningOutputTokens is read here only so the compiler treats the parameter as used.
        // It is documentary; see method-doc for the non-double-counting invariant.
        _ = reasoningOutputTokens

        let (rate, _) = self.rate(for: modelID)
        let nonCachedInput = max(0, inputTokens - cachedInputTokens)

        let micro = Double(nonCachedInput)         * rate.inputPerMToken
                  + Double(cachedInputTokens)      * rate.cachedInputPerMToken
                  + Double(outputTokens)           * rate.outputPerMToken
        return Decimal(micro / 1_000_000.0)
    }
}

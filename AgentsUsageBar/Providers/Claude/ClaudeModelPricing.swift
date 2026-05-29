import Foundation

// MARK: - Error

public enum ClaudeModelPricingError: Error, Sendable {
    case bundleResourceMissing
    case decodeFailed(Error)
}

// MARK: - Main struct

/// Bundled USD pricing table for Claude models.
///
/// Loaded from `claude-models.json` shipped in the app bundle.
/// Provides cascade lookup (exact → prefix → heuristic → file default)
/// and a `Decimal`-based cost calculator per Phase 1 D-28 precedent.
///
/// THREAT NOTE (T-02.02-02): No `os.Logger` calls in this file.
/// Pricing values are non-sensitive but the discipline keeps logging surface minimal.
public struct ClaudeModelPricing: Decodable, Sendable {

    // MARK: - Rate

    public struct Rate: Decodable, Sendable, Equatable {
        public let inputPer1M: Double
        public let outputPer1M: Double
        public let cacheWritePer1M: Double
        public let cacheReadPer1M: Double
    }

    // MARK: - LookupSource

    public enum LookupSource: Sendable, Equatable {
        case exact
        case prefix(matched: String)
        case heuristic(family: String)
        case defaultFallback
        case nilModel
    }

    // MARK: - Stored properties

    public let schemaVersion: Int
    public let lastUpdated: String       // ISO date string, e.g. "2026-05-13"

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
    /// Throws `ClaudeModelPricingError.bundleResourceMissing` when the resource is absent
    /// (e.g. running in unit-test context where Bundle.main is the test runner).
    /// Callers (Plan 02.04) catch this and degrade to a "pricing unavailable" placeholder
    /// rather than crashing — satisfying T-02.02-03.
    public static func loadBundled() throws -> ClaudeModelPricing {
        guard let url = Bundle.main.url(forResource: "claude-models", withExtension: "json") else {
            throw ClaudeModelPricingError.bundleResourceMissing
        }
        return try load(from: url)
    }

    /// Loads pricing from an arbitrary URL. Used by tests (fixture path) and previews.
    public static func load(from url: URL) throws -> ClaudeModelPricing {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            // keyDecodingStrategy = .convertFromSnakeCase is set but our JSON already uses
            // camelCase keys (inputPer1M etc.). It is a no-op for already-camel keys and
            // provides a safety net for any future snake_case fields.
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(ClaudeModelPricing.self, from: data)
        } catch let error as ClaudeModelPricingError {
            throw error
        } catch {
            throw ClaudeModelPricingError.decodeFailed(error)
        }
    }

    // MARK: - Cascade lookup

    /// Returns the rate for `modelID` and the source that produced it.
    ///
    /// Cascade order (RESEARCH §C.1 + ClaudeBar idiom):
    /// 1. Exact match on model ID key.
    /// 2. Prefix match: `modelID.hasPrefix(key)` OR `key.hasPrefix(modelID)`.
    /// 3. Family heuristic: model ID lowercased contains "opus", "sonnet", or "haiku".
    ///    For each family match, picks the entry with the **highest `inputPer1M`**
    ///    (newest/premium tier dominates pricing).
    ///    Family iteration order is deterministic: `["opus", "sonnet", "haiku"]`.
    ///    THREAT NOTE (T-02.02-04): an adversarial model name like
    ///    "claude-opus-haiku-fusion" will match "opus" first — predictable by design.
    /// 4. File-level `default`.
    public func rate(for modelID: String?) -> (rate: Rate, source: LookupSource) {
        guard let modelID, !modelID.isEmpty else {
            return (`default`, .nilModel)
        }

        // 1. Exact match
        if let r = models[modelID] {
            return (r, .exact)
        }

        // 2. Prefix match (RESEARCH §C.1 — modelID hasPrefix key, OR key hasPrefix modelID)
        for (key, r) in models {
            if modelID.hasPrefix(key) || key.hasPrefix(modelID) {
                return (r, .prefix(matched: key))
            }
        }

        // 3. Family heuristic — opus / sonnet / haiku
        let lower = modelID.lowercased()
        for family in ["opus", "sonnet", "haiku"] where lower.contains(family) {
            // Pick the family member with the highest inputPer1M (newest tier dominates pricing).
            // Filter: key must contain the family name (e.g. "claude-opus-..." or "opus-...").
            let candidates = models.filter { $0.key.lowercased().contains(family) }
            if let pick = candidates.max(by: { $0.value.inputPer1M < $1.value.inputPer1M }) {
                return (pick.value, .heuristic(family: family))
            }
        }

        // 4. File-level default
        return (`default`, .defaultFallback)
    }

    // MARK: - Cost calculator

    /// Computes the USD cost for a single transcript record using `Decimal` arithmetic.
    ///
    /// Formula: `(input×inputPer1M + output×outputPer1M + cacheCreation×cacheWritePer1M
    ///            + cacheRead×cacheReadPer1M) / 1_000_000`
    ///
    /// Uses `Decimal` cast at the final step per Phase 1 D-28 precedent — avoids IEEE 754
    /// drift on small monetary values that accumulate across thousands of JSONL records.
    ///
    /// - Parameters:
    ///   - inputTokens: Raw input token count from the transcript record.
    ///   - outputTokens: Raw output token count.
    ///   - cacheCreationTokens: Cache write token count.
    ///   - cacheReadTokens: Cache read token count (priced at 0.10× input rate per Anthropic 2026).
    ///   - modelID: Claude model ID from the transcript record (nil → file-level default).
    /// - Returns: USD cost as `Decimal`.
    public func cost(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        modelID: String?
    ) -> Decimal {
        let (rate, _) = self.rate(for: modelID)
        let micro = Double(inputTokens)          * rate.inputPer1M
                  + Double(outputTokens)         * rate.outputPer1M
                  + Double(cacheCreationTokens)  * rate.cacheWritePer1M
                  + Double(cacheReadTokens)       * rate.cacheReadPer1M
        return Decimal(micro / 1_000_000.0)
    }
}

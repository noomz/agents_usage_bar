import Foundation

// MARK: - GeminiQuotaResponse
//
// Decoded shape of `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`.
//
// RESEARCH §"Gemini Quota" — every bucket carries a remaining-fraction
// (0.0–1.0; 1.0 = fully available, 0.0 = depleted), a model id, a token
// type, and an ISO-8601 reset time. Multiple buckets per modelId are
// possible (one for INPUT_TOKEN, one for OUTPUT_TOKEN); the provider
// folds them by keeping the LOWEST `remainingFraction` per model.
//
// All fields are optional via `decodeIfPresent` semantics to tolerate
// partial responses for account states the API may not fully populate
// (Pitfall 7 / lenient parsing rule). The struct is intentionally not
// `Codable` (only `Decodable`) — we never serialise quota responses
// back to disk.

/// Decoded `retrieveUserQuota` response: an array of per-model buckets.
public struct GeminiQuotaResponse: Decodable, Sendable, Equatable {

    /// Per-model bucket — keys come back snake_case from the v1internal
    /// endpoint and are mapped via explicit `CodingKeys` so we never
    /// rely on a global `keyDecodingStrategy = .convertFromSnakeCase`
    /// (Plan 03-05 has the cautionary precedent — strategy clobbers
    /// explicit keys; the Codex/Claude convention is plain `JSONDecoder()`).
    public struct Bucket: Decodable, Sendable, Equatable {

        public let remainingFraction: Double?
        public let resetTime: String?
        public let modelId: String?
        public let tokenType: String?
        public let remainingAmount: String?

        // G-03 (UAT 2026-05-18): the live `v1internal:retrieveUserQuota`
        // endpoint returns CAMEL-CASE keys (`remainingFraction`, `modelId`,
        // `resetTime`, `tokenType`, `remainingAmount`) — NOT snake_case as
        // the original RESEARCH §"Gemini Quota" notes implied. The bearer
        // postJSON path uses a plain JSONDecoder (no .convertFromSnakeCase
        // strategy — see URLSessionHTTPClient.performPostJSON:209), so the
        // CodingKey rawValues MUST match the wire camelCase form. Each case
        // uses its default rawValue (= the case name) to express that.
        private enum CodingKeys: String, CodingKey {
            case remainingFraction
            case resetTime
            case modelId
            case tokenType
            case remainingAmount
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.remainingFraction = try c.decodeIfPresent(Double.self, forKey: .remainingFraction)
            self.resetTime = try c.decodeIfPresent(String.self, forKey: .resetTime)
            self.modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
            self.tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType)
            self.remainingAmount = try c.decodeIfPresent(String.self, forKey: .remainingAmount)
        }

        /// Memberwise init for tests / fixtures.
        public init(
            remainingFraction: Double?,
            resetTime: String?,
            modelId: String?,
            tokenType: String?,
            remainingAmount: String?
        ) {
            self.remainingFraction = remainingFraction
            self.resetTime = resetTime
            self.modelId = modelId
            self.tokenType = tokenType
            self.remainingAmount = remainingAmount
        }

        // MARK: - resetTime parsing (Pitfall 3 — dual ISO formatter)

        nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        nonisolated(unsafe) private static let isoNoFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        /// Parses `resetTime` with fractional seconds first, then without
        /// (RESEARCH §"Gemini Quota" + STATE #43 dual-formatter precedent).
        /// Returns `nil` when `resetTime` is absent or unparseable.
        public func resetTimeAsDate() -> Date? {
            guard let s = resetTime else { return nil }
            return Self.isoFractional.date(from: s)
                ?? Self.isoNoFractional.date(from: s)
        }
    }

    /// Per-model buckets. May be `nil` for account states the API does
    /// not yet populate (returns an empty top-level object).
    public let buckets: [Bucket]?

    private enum CodingKeys: String, CodingKey {
        case buckets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.buckets = try c.decodeIfPresent([Bucket].self, forKey: .buckets)
    }

    /// Memberwise init for tests.
    public init(buckets: [Bucket]?) {
        self.buckets = buckets
    }
}

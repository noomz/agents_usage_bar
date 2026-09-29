import Foundation

/// `GET https://ollama.com/api/usage` (undocumented; SPEC I1, C1). Every field is
/// optional and unknown keys are ignored so a shape change degrades, not crashes.
///
/// ```json
/// {"activity": {"cost": "0.00000", "models": [], "period": {...}},
///  "limits": {"monthly": {"usage": 0.25, "models": []}}}
/// ```
public struct OllamaUsageResponse: Decodable, Sendable, Equatable {
    public let activity: Activity?
    public let limits: Limits?

    public struct Activity: Decodable, Sendable, Equatable {
        /// Own spend over `period` (rolling last 4 weeks), decimal USD as a string.
        public let cost: String?
    }

    public struct Limits: Decodable, Sendable, Equatable {
        public let monthly: Window?
    }

    public struct Window: Decodable, Sendable, Equatable {
        /// Fraction (0–1) of the plan's monthly included usage consumed.
        public let usage: Double?
    }
}

/// `POST https://ollama.com/api/me`. Only `Plan` is decoded — the response also
/// carries personal fields (email, name, id, avatar) that must never be read (SPEC V19).
public struct OllamaMeResponse: Decodable, Sendable, Equatable {
    public let plan: String?

    enum CodingKeys: String, CodingKey {
        case plan = "Plan"
    }
}

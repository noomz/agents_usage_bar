import Foundation

/// Decodable model for `GET http://localhost:11434/api/ps` — running models.
///
/// **Wire shape (RESEARCH §2.1, verified against Ollama API docs 2026-05):**
/// ```json
/// { "models": [
///     { "name": "llama3:8b", "model": "llama3:8b",
///       "size": 5137025024, "size_vram": 5137025024,
///       "details": { "family": "llama", "parameter_size": "7.2B", "quantization_level": "Q4_0" },
///       "expires_at": "2026-06-04T14:38:31Z" } ] }
/// ```
///
/// **Fields we read (D-02 / D-03 / D-03 tooltip):**
/// - `models[].name` — primary display name (D-03 row state)
/// - `models[].size_vram` — VRAM bytes; suffix `"X.X GB VRAM"` in secondary line (D-02)
/// - `models[].details.family` — tooltip only
/// - `models[].details.parameter_size` — tooltip only
/// - `models[].details.quantization_level` — tooltip only
///
/// **Fields we ignore (lenient parse — Pitfall 7):**
/// `model`, `digest`, `size` (non-VRAM total), `details.parent_model`, `details.format`,
/// `details.families[]`, `expires_at`. Future Ollama fields decode without error per
/// Swift's synthesised `Decodable` behaviour (Phase 3 STATE #64 — no `AnyCodable` plumbing).
///
/// **Decoder:** plain `JSONDecoder()` (NO `.convertFromSnakeCase`) because `CodingKeys`
/// are declared explicitly for snake_case fields — Phase 3 STATE #67 / Plan 03-04 lesson.
/// `OllamaProvider` calls `http.get(..., useSnakeCaseConversion: false, ...)`.
public struct OllamaPsResponse: Decodable, Sendable, Equatable {

    /// Currently-loaded models. Optional so an absent or `null` key doesn't throw
    /// (Pitfall 7 leniency — `{"models": null}` shape).
    public let models: [Model]?

    private enum CodingKeys: String, CodingKey {
        case models
    }

    // MARK: - Model

    public struct Model: Decodable, Sendable, Equatable {

        /// Primary display name, e.g. `"llama3:8b"`.
        public let name: String

        /// VRAM bytes used by this model. `Int64` explicitly per Pitfall 11 (RESEARCH §10 row 11):
        /// a 70B Q5_K_M model can exceed 50 GB → exceeds `Int32.max` on hypothetical 32-bit hosts.
        /// `nil` when the model is running CPU-only (`OLLAMA_NUM_GPU=0`) and Ollama omits the field.
        public let sizeVram: Int64?

        /// Model metadata (family, parameter_size, quantization_level).
        /// Surfaced in tooltip; may be absent on older Ollama builds.
        public let details: Details?

        private enum CodingKeys: String, CodingKey {
            case name
            case sizeVram = "size_vram"
            case details
        }
    }

    // MARK: - Details

    public struct Details: Decodable, Sendable, Equatable {

        /// Model architecture family, e.g. `"llama"`, `"phi"`.
        public let family: String?

        /// Human-readable parameter count string, e.g. `"7.2B"`, `"8.0B"`.
        public let parameterSize: String?

        /// Quantization level string, e.g. `"Q4_0"`, `"Q5_K_M"`.
        public let quantizationLevel: String?

        private enum CodingKeys: String, CodingKey {
            case family
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
        }
    }
}

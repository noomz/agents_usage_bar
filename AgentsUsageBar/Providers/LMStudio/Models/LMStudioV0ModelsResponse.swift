import Foundation

/// Decodable model for `GET http://localhost:<port>/api/v0/models` — LM Studio 0.3.5+ extended schema.
///
/// **Wire shape (RESEARCH §2.2, verified against LM Studio API docs 2026-05):**
/// ```json
/// { "object": "list",
///   "data": [
///     { "id": "meta-llama-3.1-8b-instruct", "object": "model", "type": "llm",
///       "publisher": "lmstudio-community", "arch": "llama",
///       "compatibility_type": "gguf", "quantization": "Q4_K_M",
///       "state": "loaded", "max_context_length": 131072, "loaded_context_length": 4096 } ] }
/// ```
///
/// **Fields we read (D-02 / D-03 row state computation):**
/// - `data[].id` — primary display name / model identifier
/// - `data[].state` — `"loaded" | "not-loaded"` (absent on older builds — treated as loaded)
/// - `data[].arch` — tooltip only
/// - `data[].quantization` — tooltip only
/// - `data[].loaded_context_length` — tooltip only when present
///
/// **Fields we ignore (lenient parse — Pitfall 7):**
/// `object`, `type`, `publisher`, `compatibility_type`, `max_context_length`,
/// plus any future fields LM Studio adds. Swift's synthesised `Decodable` already
/// tolerates unknown keys (Phase 3 STATE #64 — no `AnyCodable` plumbing needed).
///
/// **Decoder:** plain `JSONDecoder()` (NO `.convertFromSnakeCase`) because `CodingKeys`
/// are declared explicitly for snake_case fields — Phase 3 STATE #67.
/// `LMStudioProvider` calls `http.get(..., useSnakeCaseConversion: false, ...)`.
public struct LMStudioV0ModelsResponse: Decodable, Sendable, Equatable {

    /// Container shape. Optional so an absent or `null` key doesn't throw (Pitfall 7 leniency).
    public let object: String?

    /// Model entries. Optional outer per RESEARCH §2.2 lenient handling.
    public let data: [Model]?

    /// Returns the subset of models that are currently loaded.
    ///
    /// When `state` is nil (older LM Studio without extended schema), treat the model as loaded
    /// by default — RESEARCH §2.2 "fall back to OAI-compat treat ALL listed models as loaded".
    public var loadedModels: [Model] {
        (data ?? []).filter { ($0.state ?? "loaded") == "loaded" }
    }

    // MARK: - Model

    public struct Model: Decodable, Sendable, Equatable {

        /// Model identifier / display name, e.g. `"meta-llama-3.1-8b-instruct"`.
        public let id: String

        /// Load state: `"loaded"` or `"not-loaded"`.
        /// Optional because older LM Studio builds (< 0.3.5) may omit the field (RESEARCH §2.2 Pitfall 7).
        /// When absent, `loadedModels` treats the model as loaded (best-effort).
        public let state: String?

        /// Model architecture family, e.g. `"llama"`, `"phi"`. Tooltip only.
        public let arch: String?

        /// Quantization descriptor, e.g. `"Q4_K_M"`, `"4bit"`. Tooltip only.
        public let quantization: String?

        /// Context length actually loaded into memory. Tooltip only when present.
        public let loadedContextLength: Int?

        private enum CodingKeys: String, CodingKey {
            case id
            case state
            case arch
            case quantization
            case loadedContextLength = "loaded_context_length"
        }
    }
}

import Foundation

/// Decodable model for `GET http://localhost:<port>/v1/models` — OpenAI-compatible fallback.
///
/// Older LM Studio builds (< 0.3.5) and the OpenAI-compat baseline. NO state field —
/// all listed models treated as loaded (best effort) — RESEARCH §2.2.
///
/// **Wire shape (RESEARCH §2.2, OpenAI-compatible):**
/// ```json
/// { "object": "list",
///   "data": [
///     { "id": "meta-llama-3.1-8b-instruct", "object": "model", "owned_by": "organization_owner" }
///   ] }
/// ```
///
/// **Fields we read:**
/// - `data[].id` — model identifier / display name
///
/// **Fields we ignore (lenient parse — Pitfall 7):**
/// `object`, `owned_by`, plus any future fields. Swift's synthesised `Decodable`
/// tolerates unknown keys without error (Phase 3 STATE #64).
///
/// **Decoder:** plain `JSONDecoder()` (NO `.convertFromSnakeCase`) — all fields use their
/// natural names; no snake_case `CodingKeys` override needed.
public struct LMStudioV1ModelsResponse: Decodable, Sendable, Equatable {

    /// Container shape. Optional so an absent or `null` key doesn't throw (Pitfall 7 leniency).
    public let object: String?

    /// Model entries. Optional outer per lenient handling.
    public let data: [Model]?

    // MARK: - Model

    public struct Model: Decodable, Sendable, Equatable {

        /// Model identifier / display name, e.g. `"meta-llama-3.1-8b-instruct"`.
        public let id: String
    }
}

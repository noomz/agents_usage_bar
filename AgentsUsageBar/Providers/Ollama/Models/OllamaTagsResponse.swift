import Foundation

/// Decodable model for `GET http://localhost:11434/api/tags` — installed models.
///
/// **Wire shape (RESEARCH §2.1, verified against Ollama API docs 2026-05):**
/// ```json
/// { "models": [
///     { "name": "codellama:13b", "modified_at": "...", "size": 7365960935, ... } ] }
/// ```
///
/// **Fields we read:**
/// - `models[].name` — model identifier. Purpose: distinguish D-03 row states
///   `"Idle — 0 models loaded"` (server up, `/api/ps` empty, `/api/tags` non-empty)
///   from `"Idle — no models installed"` (server up, both empty).
///
/// **Fields we ignore (lenient parse — Pitfall 7):**
/// `modified_at`, `size`, `digest`, `details` — all silently ignored by the decoder.
/// Future Ollama fields decode without error per Swift's synthesised `Decodable`
/// behaviour (Phase 3 STATE #64 — no `AnyCodable` plumbing required).
///
/// **Decoder:** plain `JSONDecoder()` (NO `.convertFromSnakeCase`) because `CodingKeys`
/// are explicit — Phase 3 STATE #67 convention.
public struct OllamaTagsResponse: Decodable, Sendable, Equatable {

    /// Installed (not necessarily loaded) models. Optional for leniency
    /// (Pitfall 7 — `{"models": null}` edge case).
    public let models: [Model]?

    // MARK: - Model

    public struct Model: Decodable, Sendable, Equatable {

        /// Model identifier, e.g. `"codellama:13b"`. Only field read by `OllamaProvider`.
        public let name: String
    }
}

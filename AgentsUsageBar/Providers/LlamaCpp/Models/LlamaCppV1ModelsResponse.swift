import Foundation

/// Decodable model for `GET http://localhost:<port>/v1/models` — OpenAI-compatible model list.
///
/// **Wire shape (RESEARCH §2.3, verified against llama.cpp `examples/server/README.md` 2026-05):**
/// ```json
/// {
///   "object": "list",
///   "data": [
///     {
///       "id": "/path/to/llama-3-8b-instruct-Q4_K_M.gguf",
///       "object": "model",
///       "created": 1717024812,
///       "owned_by": "llamacpp",
///       "meta": { "n_ctx_train": 8192, "n_embd": 4096, "n_params": 8030261248 }
///     }
///   ]
/// }
/// ```
///
/// llama.cpp is a single-model server — `data[0]` is the loaded model.
/// The `id` field is the full filesystem path to the GGUF file; trim to basename
/// via `URL(fileURLWithPath:).lastPathComponent` (RESEARCH §2.3 Apple URL API;
/// do NOT split on `"/"` manually).
///
/// **Fields we ignore (lenient parse — Pitfall 7):** `object`, `created`, `owned_by`, `meta`
/// and any future fields. Swift's synthesised `Decodable` tolerates unknown fields.
///
/// **LOCAL-06:** no `tokensToday`, `tokenCount`, or `costTodayUSD` anywhere in this file.
public struct LlamaCppV1ModelsResponse: Decodable, Sendable, Equatable {

    /// Top-level `"object"` field (e.g. `"list"`). Optional for Pitfall 7 leniency.
    public let object: String?

    /// Array of model descriptors. Optional so an absent or `null` field decodes as `nil`.
    public let data: [Model]?

    // MARK: - Nested model

    public struct Model: Decodable, Sendable, Equatable {
        /// Full filesystem path to the GGUF file, e.g. `"/Users/test/models/llama-3-8b.gguf"`.
        public let id: String
    }

    // MARK: - Helper

    /// Basename of the first model's file path, trimmed via `URL(fileURLWithPath:).lastPathComponent`.
    ///
    /// Example: `"/Users/test/models/llama-3-8b-instruct-Q4_K_M.gguf"` → `"llama-3-8b-instruct-Q4_K_M.gguf"`.
    /// Returns `nil` when `data` is empty or absent.
    public var modelBasename: String? {
        data?.first.map { URL(fileURLWithPath: $0.id).lastPathComponent }
    }
}

import Foundation

/// Decodable model for `GET http://localhost:<port>/health` — server liveness + model-load state.
///
/// **Wire shapes (RESEARCH §2.3, verified against llama.cpp `examples/server/README.md` 2026-05):**
///
/// Healthy:
/// ```json
/// { "status": "ok", "slots_idle": 4, "slots_processing": 0 }
/// ```
///
/// Warming up (model loading at startup — state E per RESEARCH §5.1):
/// ```json
/// { "status": "loading model" }
/// ```
///
/// All slots busy:
/// ```json
/// { "status": "no slot available", "slots_idle": 0, "slots_processing": 4 }
/// ```
///
/// Error (model failed to load):
/// ```json
/// { "status": "error" }
/// ```
///
/// **OQ-3 mitigation:** if `status` doesn't match any of the four documented strings,
/// the lenient discriminator helpers treat it as `.ok` (best-effort) to prevent
/// llamafile-version-drift from flashing false-alarm red rows.
///
/// **Decoder:** plain `JSONDecoder()` (NO `.convertFromSnakeCase`) because `CodingKeys`
/// are declared explicitly for snake_case fields — Phase 3 STATE #67.
/// `LlamaCppProvider` calls `http.get(..., useSnakeCaseConversion: false, ...)`.
public struct LlamaCppHealthResponse: Decodable, Sendable, Equatable {

    /// Raw status string from the server. Optional so an absent or `null` key decodes
    /// as `nil` rather than throwing (Pitfall 7 leniency). OQ-3: `nil` is treated as `"ok"`.
    public let status: String?

    /// Number of idle slots. Advisory only (tooltip enrichment); may be absent.
    public let slotsIdle: Int?

    /// Number of processing slots. Advisory only; may be absent.
    public let slotsProcessing: Int?

    private enum CodingKeys: String, CodingKey {
        case status
        case slotsIdle = "slots_idle"
        case slotsProcessing = "slots_processing"
    }

    // MARK: - Discriminator helpers

    /// `true` when the server reports healthy / ready state.
    ///
    /// OQ-3 nil-tolerant: a missing `status` field is treated as `"ok"` (best effort).
    public var isOK: Bool {
        (status ?? "ok").lowercased() == "ok"
    }

    /// `true` when the server is warming up (model loading at startup — state E).
    ///
    /// OQ-1 substring match: the documented form is `"loading model"` but a llamafile
    /// drift to `"loading"` (no "model" suffix) still matches.
    public var isLoading: Bool {
        (status ?? "").lowercased().contains("loading")
    }

    /// `true` when the server reports `"error"` (model failed to load).
    public var isErrorStatus: Bool {
        (status ?? "").lowercased() == "error"
    }

    /// `true` when all slots are busy (`"no slot available"`). Server is still running.
    public var hasNoSlot: Bool {
        (status ?? "").lowercased().contains("no slot")
    }
}

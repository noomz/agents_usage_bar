import Foundation

/// Decodable wrapper for `GET http://localhost:<port>/slots` — per-slot live state.
///
/// **RESEARCH §2.3 — opportunistic probe; failures silently ignored (best-effort tooltip enrichment only).**
///
/// The endpoint returns a **JSON array** (not an object) per llama.cpp README:
/// ```json
/// [
///   {
///     "id": 0,
///     "id_task": -1,
///     "state": "idle",
///     "prompt": "",
///     "next_token": { "has_next_token": false, "n_remain": -1 }
///   }
/// ]
/// ```
///
/// A wrapper struct is used for testability — decodes the top-level array via an
/// `unkeyedContainer` in a custom `init(from:)`.
///
/// **Fields we read:** `id`, `state` — enough for the `"X slots, Y idle / Z busy"` tooltip summary.
/// **Fields we ignore (lenient parse — Pitfall 7):** `id_task`, `prompt`, `next_token`, `params`,
/// and any future fields. Unknown keys in each slot object are silently dropped by synthesised
/// `Decodable` on `LlamaCppSlot`.
///
/// **LOCAL-06:** no `tokensToday`, `tokenCount`, or `costTodayUSD` anywhere in this file.
public struct LlamaCppSlotsResponse: Decodable, Sendable, Equatable {

    /// The decoded per-slot entries.
    public let slots: [LlamaCppSlot]

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var slots: [LlamaCppSlot] = []
        while !container.isAtEnd {
            let slot = try container.decode(LlamaCppSlot.self)
            slots.append(slot)
        }
        self.slots = slots
    }

    // Memberwise init for tests.
    public init(slots: [LlamaCppSlot]) {
        self.slots = slots
    }
}

/// A single slot entry from the `/slots` array.
public struct LlamaCppSlot: Decodable, Sendable, Equatable {

    /// Slot index (0-based). May be absent on some builds.
    public let id: Int?

    /// Slot state string: `"idle"`, `"processing"`, or other runtime-specific values.
    public let state: String?
}

import Foundation

// MARK: - GeminiLoadCodeAssistResponse
//
// Decoded shape of `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`.
//
// RESEARCH §"Gemini Tier" — the field of interest for the tooltipLabel
// (D-15 / GEMINI-03) is `currentTier.id`. The endpoint additionally
// returns `cloudaicompanionProject`, which comes back in BOTH shapes in
// production (per CodexBar GeminiStatusProbe.loadCodeAssistStatus):
//   - plain string:  "gen-lang-client-0123"
//   - nested object: { "id": "gen-lang-client-0123" } or
//                    { "projectId": "gen-lang-client-0123" }
// The decoder normalises to a String at decode time so the caller does
// not need to branch.
//
// Pitfall 8 (cold-start no tier): `currentTier` may be `null` on the
// first call after a token refresh. `tierDisplayName(forID: nil)` is
// the silent-no-tooltip branch — never throws, never produces "Unknown".

/// Decoded `loadCodeAssist` response (relevant fields only).
public struct GeminiLoadCodeAssistResponse: Decodable, Sendable, Equatable {

    /// `currentTier` sub-object (RESEARCH §"Gemini Tier" /
    /// gemini-cli types.ts UserTierId).
    public struct CurrentTier: Decodable, Sendable, Equatable {

        public let id: String?
        public let name: String?
        public let hasAcceptedTos: Bool?
        public let hasOnboardedPreviously: Bool?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case hasAcceptedTos
            case hasOnboardedPreviously
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decodeIfPresent(String.self, forKey: .id)
            self.name = try c.decodeIfPresent(String.self, forKey: .name)
            self.hasAcceptedTos = try c.decodeIfPresent(Bool.self, forKey: .hasAcceptedTos)
            self.hasOnboardedPreviously = try c.decodeIfPresent(Bool.self, forKey: .hasOnboardedPreviously)
        }

        /// Memberwise init for tests.
        public init(
            id: String?,
            name: String?,
            hasAcceptedTos: Bool?,
            hasOnboardedPreviously: Bool?
        ) {
            self.id = id
            self.name = name
            self.hasAcceptedTos = hasAcceptedTos
            self.hasOnboardedPreviously = hasOnboardedPreviously
        }
    }

    /// Current tier sub-object. May be `nil` on cold-start (Pitfall 8).
    public let currentTier: CurrentTier?

    /// Normalised to a plain String at decode time, regardless of whether
    /// the wire shape is a String or an Object with `id` / `projectId`.
    public let cloudaicompanionProject: String?

    private enum CodingKeys: String, CodingKey {
        case currentTier
        case cloudaicompanionProject
    }

    /// Nested keys for the Object form of cloudaicompanionProject.
    private enum ProjectObjectKeys: String, CodingKey {
        case id
        case projectId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.currentTier = try c.decodeIfPresent(CurrentTier.self, forKey: .currentTier)

        // Try the plain String form first (most common in production).
        if let s = try? c.decodeIfPresent(String.self, forKey: .cloudaicompanionProject) {
            self.cloudaicompanionProject = s
        } else if c.contains(.cloudaicompanionProject) {
            // Fall back to the Object form. Both `id` and `projectId`
            // sub-fields appear in production per CodexBar's reference
            // implementation; prefer `id`, then `projectId`, else nil.
            if let nested = try? c.nestedContainer(
                keyedBy: ProjectObjectKeys.self,
                forKey: .cloudaicompanionProject
            ) {
                let id = try? nested.decodeIfPresent(String.self, forKey: .id)
                let projectId = try? nested.decodeIfPresent(String.self, forKey: .projectId)
                self.cloudaicompanionProject = id ?? projectId
            } else {
                self.cloudaicompanionProject = nil
            }
        } else {
            self.cloudaicompanionProject = nil
        }
    }

    /// Memberwise init for tests.
    public init(currentTier: CurrentTier?, cloudaicompanionProject: String?) {
        self.currentTier = currentTier
        self.cloudaicompanionProject = cloudaicompanionProject
    }

    // MARK: - Tier display mapping (RESEARCH correction #6)

    /// Maps `currentTier.id` to the tooltip-friendly display name.
    ///
    /// - `"free-tier"`    → `"Free"`
    /// - `"legacy-tier"`  → `"Legacy"`
    /// - `"standard-tier"` → `"Paid"`
    /// - any other non-nil string → returned verbatim (lenient — surfaces
    ///   future tier names without a code change)
    /// - `nil` → `nil` (silent — Pitfall 8 cold-start, never "Unknown")
    public static func tierDisplayName(forID id: String?) -> String? {
        guard let id else { return nil }
        switch id {
        case "free-tier":     return "Free"
        case "legacy-tier":   return "Legacy"
        case "standard-tier": return "Paid"
        default:              return id
        }
    }
}

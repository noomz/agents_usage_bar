import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("ClaudeHookPayload")
struct ClaudeHookPayloadTests {

    // MARK: - Fixtures

    /// Full payload: session, model, cost, and both rate-limit windows.
    private static let fullJSON = """
    {
      "session_id": "sess-abc",
      "model": { "id": "claude-opus-4-8", "display_name": "Opus 4.8" },
      "cost": { "total_cost_usd": 1.234567 },
      "rate_limits": {
        "five_hour": { "used_percentage": 42.5, "resets_at": 1752768000 },
        "seven_day": { "used_percentage": 7.0, "resets_at": 1753286400 }
      }
    }
    """

    private func decode(_ s: String) throws -> ClaudeHookPayload {
        try ClaudeHookPayload.decode(Data(s.utf8))
    }

    // MARK: - Tests

    @Test func decodesFullPayload() throws {
        let p = try decode(Self.fullJSON)

        #expect(p.sessionId == "sess-abc")
        #expect(p.model?.id == "claude-opus-4-8")
        #expect(p.model?.displayName == "Opus 4.8")
        #expect(p.cost?.totalCostUsd == 1.234567)
        #expect(p.rateLimits?.fiveHour?.usedPercentage == 42.5)
        #expect(p.rateLimits?.sevenDay?.usedPercentage == 7.0)
    }

    @Test func transcriptPathDecodes() throws {
        let json = """
        { "session_id": "s", "transcript_path": "/Users/x/.ccs/instances/personal/projects/p/s.jsonl" }
        """
        let p = try decode(json)
        #expect(p.transcriptPath == "/Users/x/.ccs/instances/personal/projects/p/s.jsonl")
    }

    @Test func epochResetsAtConvertsToDate() throws {
        let p = try decode(Self.fullJSON)

        // resets_at is Unix epoch SECONDS.
        #expect(p.rateLimits?.fiveHour?.resetsAt == 1_752_768_000)
        #expect(p.rateLimits?.fiveHour?.resetsAtDate == Date(timeIntervalSince1970: 1_752_768_000))
        #expect(p.rateLimits?.sevenDay?.resetsAtDate == Date(timeIntervalSince1970: 1_753_286_400))
    }

    @Test func missingRateLimits_decodesWithNil() throws {
        // API-key users: no rate_limits object at all.
        let json = """
        {
          "session_id": "sess-2",
          "cost": { "total_cost_usd": 0.5 }
        }
        """
        let p = try decode(json)

        #expect(p.sessionId == "sess-2")
        #expect(p.cost?.totalCostUsd == 0.5)
        #expect(p.rateLimits == nil)
    }

    @Test func oneWindowAbsent_decodesOtherWindow() throws {
        // seven_day present, five_hour absent.
        let json = """
        {
          "rate_limits": {
            "seven_day": { "used_percentage": 12.0, "resets_at": 1753286400 }
          }
        }
        """
        let p = try decode(json)

        #expect(p.rateLimits?.fiveHour == nil)
        #expect(p.rateLimits?.sevenDay?.usedPercentage == 12.0)
    }

    @Test func nullPercentages_decodeAsNil() throws {
        // Percentages can be null in the early moments of a session.
        let json = """
        {
          "rate_limits": {
            "five_hour": { "used_percentage": null, "resets_at": 1752768000 },
            "seven_day": { "used_percentage": null, "resets_at": null }
          }
        }
        """
        let p = try decode(json)

        #expect(p.rateLimits?.fiveHour?.usedPercentage == nil)
        #expect(p.rateLimits?.fiveHour?.resetsAtDate == Date(timeIntervalSince1970: 1_752_768_000))
        #expect(p.rateLimits?.sevenDay?.usedPercentage == nil)
        #expect(p.rateLimits?.sevenDay?.resetsAt == nil)
        #expect(p.rateLimits?.sevenDay?.resetsAtDate == nil)
    }

    @Test func emptyObject_decodesAllNil() throws {
        let p = try decode("{}")

        #expect(p.sessionId == nil)
        #expect(p.model == nil)
        #expect(p.cost == nil)
        #expect(p.rateLimits == nil)
    }
}

import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Fixture helpers

private func loadFixtureData(named name: String) throws -> Data {
    let thisFile = URL(fileURLWithPath: #filePath)
    return try Data(contentsOf: thisFile
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name))
}

// MARK: - CodexUsageResponseTests

@Suite("CodexUsageResponseTests")
struct CodexUsageResponseTests {

    private let decoder = JSONDecoder()

    // MARK: - 1. Full fixture decode

    @Test func fullFixtureDecodes_withCorrectWhamUsageShape() throws {
        let data = try loadFixtureData(named: "codex-wham-usage-fixture.json")
        let response = try decoder.decode(CodexUsageResponse.self, from: data)

        #expect(response.planType == "plus")

        let rateLimit = try #require(response.rateLimit)
        let primary = try #require(rateLimit.primaryWindow)
        let secondary = try #require(rateLimit.secondaryWindow)

        #expect(primary.usedPercent == 48)
        #expect(primary.resetAt == 1777970900)
        #expect(primary.limitWindowSeconds == 18000)

        #expect(secondary.usedPercent == 26)
        #expect(secondary.resetAt == 1778060488)
        #expect(secondary.limitWindowSeconds == 604800)

        let credits = try #require(response.credits)
        #expect(credits.hasCredits == false)
        #expect(credits.unlimited == false)
        #expect(credits.balance == nil)
    }

    // MARK: - 2. Window.resetDate() normalises epoch seconds → Date

    @Test func windowResetDate_returnsAbsoluteDate_fromEpochSeconds() throws {
        let data = try loadFixtureData(named: "codex-wham-usage-fixture.json")
        let response = try decoder.decode(CodexUsageResponse.self, from: data)

        let primary = try #require(response.rateLimit?.primaryWindow)
        let secondary = try #require(response.rateLimit?.secondaryWindow)

        #expect(primary.resetDate() == Date(timeIntervalSince1970: 1777970900))
        #expect(secondary.resetDate() == Date(timeIntervalSince1970: 1778060488))
    }

    // MARK: - 3. Partial response (only primary_window) decodes

    @Test func partialResponse_onlyPrimaryWindow_decodes() throws {
        let body = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 12, "reset_at": 1700000000, "limit_window_seconds": 18000 }
          }
        }
        """
        let response = try decoder.decode(CodexUsageResponse.self, from: Data(body.utf8))

        #expect(response.planType == "pro")
        let rateLimit = try #require(response.rateLimit)
        let primary = try #require(rateLimit.primaryWindow)
        #expect(primary.usedPercent == 12)
        #expect(rateLimit.secondaryWindow == nil)
        #expect(response.credits == nil)
    }

    // MARK: - 4. Empty response {} decodes with all-nil fields

    @Test func emptyObject_decodesWithAllNilFields() throws {
        let response = try decoder.decode(CodexUsageResponse.self, from: Data("{}".utf8))
        #expect(response.planType == nil)
        #expect(response.rateLimit == nil)
        #expect(response.credits == nil)
    }

    // MARK: - 5. Unknown future top-level key tolerated (lenient — Pitfall 7)

    @Test func unknownFutureFields_doNotBreakDecoding() throws {
        let body = """
        {
          "plan_type": "team",
          "unknown_future_key": "x",
          "rate_limit": {
            "primary_window": { "used_percent": 5, "reset_at": 1700000000, "limit_window_seconds": 18000 },
            "tertiary_window": { "used_percent": 99 }
          },
          "new_subscription_field": { "foo": "bar" }
        }
        """
        let response = try decoder.decode(CodexUsageResponse.self, from: Data(body.utf8))
        #expect(response.planType == "team")
        #expect(response.rateLimit?.primaryWindow?.usedPercent == 5)
    }

    // MARK: - 6. Schema-correction regression — rollout-style keys MUST NOT decode silently

    /// Locks in correction #5: a JSON payload using the **rollout** schema keys
    /// (`rate_limits` plural, `primary`, `resets_at`, `window_minutes`) must NOT
    /// populate the `wham/usage` `rateLimit.primaryWindow.usedPercent` etc. The
    /// decoder is lenient about *unknown* keys (Pitfall 7) — but the windows it
    /// declares must use the wham/usage names. If a future refactor accidentally
    /// renames the CodingKeys to the rollout shape, this test fails.
    @Test func rolloutShapeKeys_doNotMisresolveIntoWhamUsageStruct() throws {
        let rolloutShaped = """
        {
          "plan_type": "plus",
          "rate_limits": {
            "primary":   { "used_percent": 48, "resets_at": 1777970900, "window_minutes": 300 },
            "secondary": { "used_percent": 26, "resets_at": 1778060488, "window_minutes": 10080 }
          }
        }
        """
        let response = try decoder.decode(CodexUsageResponse.self, from: Data(rolloutShaped.utf8))
        // `plan_type` is identical in both schemas — that decodes.
        #expect(response.planType == "plus")
        // But `rate_limits` (plural) ≠ `rate_limit` (singular) — so the wham/usage
        // RateLimit struct stays nil. This is the invariant.
        #expect(response.rateLimit == nil)
    }
}

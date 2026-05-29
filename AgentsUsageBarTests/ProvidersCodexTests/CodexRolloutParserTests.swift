import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Fixture helpers (#filePath-based, mirrors ProvidersClaudeTests)

private func fixtureURL(named name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func makeTempJsonl(named name: String, contents: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Suite("CodexRolloutParserTests")
struct CodexRolloutParserTests {

    // MARK: - 2026 fixture decode

    @Test func decodes_2026_fixture_returns_last_valid_event_with_total_token_usage() throws {
        // Two valid token_count events live in the 2026 fixture; the later one
        // (11:57:00) has a synthetic small payload with only `info`. The 11:56:30
        // event is the canonical one with `total_token_usage.total_tokens == 556469`.
        // Both qualify under the predicate; the fold picks the LATER timestamp.
        let url = fixtureURL(named: "codex-rollout-2026-fixture.jsonl")
        let result = try #require(CodexRolloutParser.lastTokenCount(in: [url]))
        // Last (by timestamp) is the 11:57:00 event with the synthetic small total
        let info = try #require(result.event.payload.info)
        let total = try #require(info.totalTokenUsage)
        #expect(total.totalTokens == 2)
        #expect(result.event.timestamp == "2026-04-24T11:57:00.000Z")
    }

    @Test func decodes_2026_fixture_full_event_when_isolated() throws {
        // Read the fixture, strip the later 11:57 line, and verify the 11:56:30
        // event decodes with all RESEARCH.md fields intact.
        let raw = try String(contentsOf: fixtureURL(named: "codex-rollout-2026-fixture.jsonl"), encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let isolated = lines.prefix(3).joined(separator: "\n") + "\n"
        let url = try makeTempJsonl(named: "isolated.jsonl", contents: isolated)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try #require(CodexRolloutParser.lastTokenCount(in: [url]))
        let info = try #require(result.event.payload.info)
        let total = try #require(info.totalTokenUsage)
        #expect(total.inputTokens == 551589)
        #expect(total.cachedInputTokens == 505856)
        #expect(total.outputTokens == 4880)
        #expect(total.reasoningOutputTokens == 620)
        #expect(total.totalTokens == 556469)

        let limits = try #require(result.event.payload.rateLimits)
        let primary = try #require(limits.primary)
        #expect(primary.usedPercent == 2)
        #expect(primary.windowMinutes == 300)
        #expect(primary.resetsAt == 1777024786)
        #expect(primary.resetsInSeconds == nil)
        let secondary = try #require(limits.secondary)
        #expect(secondary.windowMinutes == 10080)
        #expect(limits.planType == "plus")
        #expect(limits.credits == nil)
    }

    // MARK: - 2025 legacy decode

    @Test func decodes_2025_legacy_with_resets_in_seconds() throws {
        let url = fixtureURL(named: "codex-rollout-2025-legacy.jsonl")
        let result = try #require(CodexRolloutParser.lastTokenCount(in: [url]))
        let limits = try #require(result.event.payload.rateLimits)
        let primary = try #require(limits.primary)
        #expect(primary.resetsInSeconds == 300)
        #expect(primary.resetsAt == nil)

        // resetsAtDate(now:) must return ~300 seconds in the future relative to `now`.
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let reset = try #require(primary.resetsAtDate(now: now))
        let delta = reset.timeIntervalSince(now)
        #expect(abs(delta - 300.0) < 0.001)
    }

    // MARK: - Skip malformed line (Pitfall 5)

    @Test func malformed_truncated_line_skipped_without_throwing() throws {
        // The 2026 fixture's last line is a truncated `{"timestamp":"...` — verify
        // the parser does not throw and still returns the prior valid event.
        let url = fixtureURL(named: "codex-rollout-2026-fixture.jsonl")
        let result = try #require(CodexRolloutParser.lastTokenCount(in: [url]))
        // If the truncated line had thrown, `result` would have been the previous
        // 11:57 event regardless. The point of this test is "no throw" — covered
        // by the `try` boundary in the helper. Assert non-nil here.
        #expect(result.event.type == "event_msg")
    }

    // MARK: - Unknown future field tolerance (CLAUDE-03 / Pitfall 7)

    @Test func unknown_future_field_does_not_break_decoding() throws {
        let synthetic = """
        {"timestamp":"2026-06-01T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"total_tokens":2},"unknown_future_metric":"foo"},"unknown_payload_key":42}}
        """
        let url = try makeTempJsonl(named: "synthetic.jsonl", contents: synthetic)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try #require(CodexRolloutParser.lastTokenCount(in: [url]))
        let total = try #require(result.event.payload.info?.totalTokenUsage)
        #expect(total.totalTokens == 2)
    }

    // MARK: - Order-independence

    @Test func order_independent_returns_latest_timestamp_regardless_of_input_order() throws {
        // File A has the LATER event (11:58 utc), file B has an EARLIER event (10:00 utc).
        // Supply them in [B, A] order; expect A's event.
        let earlier = """
        {"timestamp":"2026-04-24T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"total_tokens":2}}}}
        """
        let later = """
        {"timestamp":"2026-04-24T11:58:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999,"cached_input_tokens":0,"output_tokens":1,"total_tokens":1000}}}}
        """
        let urlB = try makeTempJsonl(named: "B.jsonl", contents: earlier)
        let urlA = try makeTempJsonl(named: "A.jsonl", contents: later)
        defer {
            try? FileManager.default.removeItem(at: urlB.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: urlA.deletingLastPathComponent())
        }

        let result = try #require(CodexRolloutParser.lastTokenCount(in: [urlB, urlA]))
        #expect(result.event.timestamp == "2026-04-24T11:58:00.000Z")
        let total = try #require(result.event.payload.info?.totalTokenUsage)
        #expect(total.totalTokens == 1000)
        #expect(result.fileURL.lastPathComponent == "A.jsonl")
    }

    // MARK: - Empty input + no-token-count

    @Test func empty_file_list_returns_nil() throws {
        #expect(CodexRolloutParser.lastTokenCount(in: []) == nil)
    }

    @Test func file_with_only_session_meta_returns_nil() throws {
        let onlyMeta = """
        {"timestamp":"2026-04-24T11:00:00.000Z","type":"session_meta","payload":{"model_provider":"openai"}}
        {"timestamp":"2026-04-24T11:00:01.000Z","type":"response_item","payload":{"role":"assistant","content":"hi"}}
        """
        let url = try makeTempJsonl(named: "no-tokens.jsonl", contents: onlyMeta)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(CodexRolloutParser.lastTokenCount(in: [url]) == nil)
    }

    // MARK: - Pitfall 11 (info == nil disqualifies the event)

    @Test func token_count_event_with_nil_info_is_skipped() throws {
        // First event in a session may have payload.type == "token_count" but
        // payload.info == nil (no model usage yet). Such events MUST be skipped
        // even though they syntactically qualify (Pitfall 11).
        let nilInfo = """
        {"timestamp":"2026-04-24T11:00:00.000Z","type":"event_msg","payload":{"type":"token_count"}}
        {"timestamp":"2026-04-24T11:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"total_tokens":2}}}}
        """
        let url = try makeTempJsonl(named: "nil-info.jsonl", contents: nilInfo)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try #require(CodexRolloutParser.lastTokenCount(in: [url]))
        #expect(result.event.timestamp == "2026-04-24T11:01:00.000Z")
        #expect(result.event.payload.info?.totalTokenUsage?.totalTokens == 2)
    }
}

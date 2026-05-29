import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Fixture loading helper

private func loadFixtureLines(named name: String) throws -> [String] {
    // #filePath-based resolution mirrors Plan 01.04 (ResponseDecodingTests) — avoids
    // relying on Bundle.module/Copy Bundle Resources for JSONL fixtures.
    let thisFile = URL(fileURLWithPath: #filePath)
    let fixtureURL = thisFile
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    let data = try Data(contentsOf: fixtureURL)
    guard let s = String(data: data, encoding: .utf8) else { return [] }
    return s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

@Suite("TranscriptRecord decoder")
struct TranscriptRecordTests {

    @Test func decodes_basic_assistant_line() throws {
        let lines = try loadFixtureLines(named: "transcript-basic.jsonl")
        let record = try #require(TranscriptRecord.decode(from: lines[1]))
        #expect(record.inputTokens == 100)
        #expect(record.outputTokens == 50)
        #expect(record.cacheCreationTokens == 20)
        #expect(record.cacheReadTokens == 300)
        #expect(record.model == "claude-sonnet-4-5")
        #expect(record.requestID == "req-001")
    }

    @Test func skips_user_line_returns_nil() throws {
        let line = #"{"type":"user","timestamp":"2026-05-13T15:30:30.000+00:00","message":{"role":"user","content":"hi"}}"#
        #expect(TranscriptRecord.decode(from: line) == nil)
    }

    @Test func skips_permission_mode_line_returns_nil() throws {
        let lines = try loadFixtureLines(named: "transcript-basic.jsonl")
        #expect(TranscriptRecord.decode(from: lines[0]) == nil)
    }

    @Test func tolerates_iso_without_fractional_seconds() throws {
        let lines = try loadFixtureLines(named: "transcript-iso-no-fractional.jsonl")
        let record = try #require(TranscriptRecord.decode(from: lines[0]))
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let parts = cal.dateComponents([.year, .month, .day], from: record.timestamp)
        #expect(parts.year == 2026)
        #expect(parts.month == 5)
        #expect(parts.day == 13)
    }

    @Test func tolerates_unknown_top_level_and_nested_fields() throws {
        let lines = try loadFixtureLines(named: "transcript-extra-fields.jsonl")
        let record = try #require(TranscriptRecord.decode(from: lines[0]))
        #expect(record.inputTokens == 10)
        #expect(record.outputTokens == 20)
        #expect(record.cacheReadTokens == 5)
        #expect(record.model == "claude-haiku-4-5")
        #expect(record.requestID == "req-200")
    }

    @Test func malformed_json_line_returns_nil_without_throwing() throws {
        let lines = try loadFixtureLines(named: "transcript-malformed-line.jsonl")
        #expect(TranscriptRecord.decode(from: lines[0]) != nil)
        #expect(TranscriptRecord.decode(from: lines[1]) == nil)
        #expect(TranscriptRecord.decode(from: lines[2]) != nil)
    }

    @Test func requestID_optional_decodes_when_present_and_nil_when_missing() throws {
        let lines = try loadFixtureLines(named: "transcript-basic.jsonl")
        let withRequestID = try #require(TranscriptRecord.decode(from: lines[1]))
        #expect(withRequestID.requestID == "req-001")

        let noRequestIDLine = #"{"type":"assistant","timestamp":"2026-05-13T15:30:00.000+00:00","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        let withoutRequestID = try #require(TranscriptRecord.decode(from: noRequestIDLine))
        #expect(withoutRequestID.requestID == nil)
    }

    @Test func totalTokens_sums_all_four_fields() throws {
        let lines = try loadFixtureLines(named: "transcript-basic.jsonl")
        let record = try #require(TranscriptRecord.decode(from: lines[1]))
        #expect(record.totalTokens == 470)
    }

    @Test func fast_path_skips_50KB_non_assistant_string_in_under_5ms() throws {
        // Synthesise a ~50KB string containing no `"type":"assistant"` substring —
        // the fast-path guard must short-circuit without invoking JSONSerialization.
        let big = String(repeating: "abc def ghi jkl mno pqr stu vwx yz0 123 ", count: 1300)
        let start = Date()
        let result = TranscriptRecord.decode(from: big)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result == nil)
        // Generous 5ms bound for CI noise (Pitfall 8 perf-claim guard).
        #expect(elapsed < 0.005)
    }
}

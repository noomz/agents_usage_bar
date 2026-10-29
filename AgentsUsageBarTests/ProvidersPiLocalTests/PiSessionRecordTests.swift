import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("PiSessionRecordTests")
struct PiSessionRecordTests {

    @Test func decode_assistant_prefers_totalTokens() {
        let line = assistantLine(provider: "DRM-SWAP", totalTokens: 33482, input: 33189, output: 293)
        let record = PiSessionRecord.decode(from: line)
        #expect(record != nil)
        #expect(record?.provider.rawValue == "DRM-SWAP")
        #expect(record?.tokens == 33482)
        #expect(record?.kind == .assistantMessage)
        #expect(record?.costUSD == 0)
    }

    @Test func decode_usage_entry() {
        let line = #"{"type":"usage","id":"u","parentId":null,"timestamp":"2026-04-22T12:00:00.000Z","kind":"cache_warm","provider":"DRM-SWAP","model":"qwen3.8-27b","usage":{"input":100,"output":0,"totalTokens":100,"cost":{"total":0.5}}}"#
        let record = PiSessionRecord.decode(from: line)
        #expect(record?.kind == .usageEntry)
        #expect(record?.tokens == 100)
        #expect(record?.costUSD == Decimal(string: "0.5"))
    }

    @Test func decode_skips_user_compaction_branch_and_malformed() {
        #expect(PiSessionRecord.decode(from: #"{"type":"message","timestamp":"2026-04-22T12:00:00Z","message":{"role":"user","provider":"DRM-SWAP"}}"#) == nil)
        #expect(PiSessionRecord.decode(from: #"{"type":"compaction","timestamp":"2026-04-22T12:00:00Z","usage":{"totalTokens":9}}"#) == nil)
        #expect(PiSessionRecord.decode(from: #"{"type":"branch_summary","timestamp":"2026-04-22T12:00:00Z","usage":{"totalTokens":9}}"#) == nil)
        #expect(PiSessionRecord.decode(from: "not-json") == nil)
        #expect(PiSessionRecord.decode(from: #"{"type":"session","timestamp":"2026-04-22T12:00:00Z"}"#) == nil)
    }

    @Test func decode_sums_parts_when_totalTokens_absent() {
        let line = #"{"type":"message","timestamp":"2026-04-22T12:00:00Z","message":{"role":"assistant","provider":"ollama","model":"m","usage":{"input":10,"output":5,"cacheRead":1,"cacheWrite":2,"reasoning":3}}}"#
        let record = PiSessionRecord.decode(from: line)
        #expect(record?.tokens == 21)
    }

    private func assistantLine(provider: String, totalTokens: Int, input: Int, output: Int) -> String {
        #"{"type":"message","timestamp":"2026-04-22T12:00:00.000Z","message":{"role":"assistant","provider":"\#(provider)","model":"qwen3.8-27b","usage":{"input":\#(input),"output":\#(output),"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":\#(totalTokens),"cost":{"total":0}}}}"#
    }
}

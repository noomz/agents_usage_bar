import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Helpers

private func makeTempFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".jsonl")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

// MARK: - Fixtures (inline to avoid Bundle.module dependency for streaming tests)

private let basicLine1 = """
{"type":"permission-mode","timestamp":"2026-05-13T15:00:00.000+00:00","mode":"acceptEdits"}
"""
private let basicLine2 = """
{"type":"assistant","timestamp":"2026-05-13T15:30:00.000+00:00","requestId":"req-001","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":20,"cache_read_input_tokens":300}}}
"""
private let basicLine3 = """
{"type":"assistant","timestamp":"2026-05-13T15:31:00.000+00:00","requestId":"req-002","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":80,"output_tokens":120,"cache_creation_input_tokens":0,"cache_read_input_tokens":340}}}
"""
private let malformedLine = "{this is not valid JSON at all"
private let assistantAppendLine = """
{"type":"assistant","timestamp":"2026-05-13T15:32:00.000+00:00","requestId":"req-999","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":7,"output_tokens":8,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
"""

@Suite("TranscriptReader")
struct TranscriptReaderTests {

    @Test func readDelta_fromOffsetZero_returnsAllAssistantRecords() async throws {
        let content = basicLine1 + "\n" + basicLine2 + "\n" + basicLine3 + "\n"
        let url = try makeTempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = TranscriptReader()
        let result = try await reader.readDelta(from: url, startOffset: 0, previousLastModified: nil)

        // permission-mode line is skipped; 2 assistant records returned
        #expect(result.records.count == 2)
        #expect(result.records[0].inputTokens == 100)
        #expect(result.records[0].requestID == "req-001")
        #expect(result.newOffset > 0)
        // newOffset should equal total file byte count since content ends with \n
        let fileSize = UInt64((content.utf8.count))
        #expect(result.newOffset == fileSize)
    }

    @Test func readDelta_secondCallWithPriorOffset_returnsZeroRecords() async throws {
        let content = basicLine1 + "\n" + basicLine2 + "\n" + basicLine3 + "\n"
        let url = try makeTempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = TranscriptReader()
        let result1 = try await reader.readDelta(from: url, startOffset: 0, previousLastModified: nil)
        let result2 = try await reader.readDelta(
            from: url,
            startOffset: result1.newOffset,
            previousLastModified: result1.lastModified
        )

        #expect(result2.records.isEmpty)
        #expect(result2.newOffset == result1.newOffset)
    }

    @Test func readDelta_secondCallAfterAppend_returnsOnlyNewRecord() async throws {
        let initial = basicLine1 + "\n" + basicLine2 + "\n"
        let url = try makeTempFile(initial)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = TranscriptReader()
        let result1 = try await reader.readDelta(from: url, startOffset: 0, previousLastModified: nil)
        #expect(result1.records.count == 1) // only basicLine2 is assistant

        // Append a new assistant line
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        let appendData = (assistantAppendLine + "\n").data(using: .utf8)!
        try fh.write(contentsOf: appendData)
        try fh.close()

        // Touch mtime to ensure it's newer
        let newMtime = result1.lastModified.addingTimeInterval(1)
        try FileManager.default.setAttributes([.modificationDate: newMtime], ofItemAtPath: url.path)

        let result2 = try await reader.readDelta(
            from: url,
            startOffset: result1.newOffset,
            previousLastModified: result1.lastModified
        )

        #expect(result2.records.count == 1)
        #expect(result2.records[0].requestID == "req-999")
        #expect(result2.records[0].inputTokens == 7)
    }

    @Test func readDelta_truncatedFile_restartsFromOffsetZero() async throws {
        // Write a 3-line file and capture result1
        let content = basicLine2 + "\n" + basicLine3 + "\n" + assistantAppendLine + "\n"
        let url = try makeTempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = TranscriptReader()
        let result1 = try await reader.readDelta(from: url, startOffset: 0, previousLastModified: nil)
        #expect(result1.records.count == 3)

        // Overwrite with single line — simulating truncation/replacement
        let truncated = basicLine2 + "\n"
        try truncated.write(to: url, atomically: true, encoding: .utf8)

        // Backdate mtime to simulate truncation (mtime < previousLastModified)
        let oldMtime = result1.lastModified.addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: oldMtime], ofItemAtPath: url.path)

        let result2 = try await reader.readDelta(
            from: url,
            startOffset: result1.newOffset,
            previousLastModified: result1.lastModified
        )

        // Should have restarted from offset 0 and decoded the 1 assistant line
        #expect(result2.records.count == 1)
        #expect(result2.records[0].requestID == "req-001")
    }

    @Test func readDelta_malformedLine_consumesBytesAndContinues() async throws {
        let line1 = """
        {"type":"assistant","timestamp":"2026-05-13T15:30:00.000+00:00","requestId":"req-300","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let line3 = """
        {"type":"assistant","timestamp":"2026-05-13T15:31:00.000+00:00","requestId":"req-301","message":{"model":"claude-sonnet-4-5","role":"assistant","usage":{"input_tokens":3,"output_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let content = line1 + "\n" + malformedLine + "\n" + line3 + "\n"
        let url = try makeTempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = TranscriptReader()
        let result = try await reader.readDelta(from: url, startOffset: 0, previousLastModified: nil)

        // 2 good records, malformed line consumed but no record emitted
        #expect(result.records.count == 2)
        #expect(result.records[0].requestID == "req-300")
        #expect(result.records[1].requestID == "req-301")
        let fileSize = UInt64(content.utf8.count)
        #expect(result.newOffset == fileSize)
    }

    @Test func readDelta_nonExistentFile_throws() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        let reader = TranscriptReader()
        await #expect(throws: (any Error).self) {
            try await reader.readDelta(from: url, startOffset: 0, previousLastModified: nil)
        }
    }

    @Test func readDelta_emptyFile_returnsZeroRecordsAndOffsetZero() async throws {
        let url = try makeTempFile("")
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = TranscriptReader()
        let result = try await reader.readDelta(from: url, startOffset: 0, previousLastModified: nil)

        #expect(result.records.isEmpty)
        #expect(result.newOffset == 0)
    }

    @Test func bytesConsumed_accountsForLF() async throws {
        // "hello" is 5 UTF-8 bytes; with the \n that .bytes.lines strips, total = 6
        let content = "hello\n"
        let url = try makeTempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = TranscriptReader()
        let result = try await reader.readDelta(from: url, startOffset: 0, previousLastModified: nil)

        // "hello" has no "type":"assistant" so records is empty, but bytes were consumed
        #expect(result.records.isEmpty)
        #expect(result.newOffset == 6) // 5 chars + 1 LF
    }
}

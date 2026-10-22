import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("HistoryReaderTests")
struct HistoryReaderTests {

    private func makeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ day: DayFile, in dir: URL) throws {
        try day.encoded().write(to: dir.appending(path: "\(day.date).json"))
    }

    @Test("missing history/ is empty and is not created (V19)")
    func missingDirectoryIsEmpty() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let reader = HistoryReader(directory: dir)
        #expect(try await reader.dayKeys() == [])
        #expect(try await reader.days() == [])
        #expect(await reader.day("2026-10-22") == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
    }

    @Test("lists day files oldest first, ignoring the salt and other files (V19, I9)")
    func listsDayFilesOnly() async throws {
        let dir = try makeDirectory()
        for key in ["2026-10-22", "2026-09-30", "2026-10-01"] {
            try write(DayFile(date: key, timeZone: "UTC"), in: dir)
        }
        try Data("salt".utf8).write(to: dir.appending(path: ".account-salt"))
        try Data().write(to: dir.appending(path: "2026-10-22.json.tmp"))
        try Data().write(to: dir.appending(path: "notes.json"))

        let reader = HistoryReader(directory: dir)
        #expect(try await reader.dayKeys() == ["2026-09-30", "2026-10-01", "2026-10-22"])
        #expect(try await reader.days().map(\.date) == ["2026-09-30", "2026-10-01", "2026-10-22"])
        #expect(try await reader.days(in: "2026-10-01"..."2026-10-31").map(\.date)
            == ["2026-10-01", "2026-10-22"])
    }

    @Test("reads a full day file back (I16)")
    func readsFullDay() async throws {
        let dir = try makeDirectory()
        let day = DayFileTests.fullDay()
        try write(day, in: dir)
        #expect(await HistoryReader(directory: dir).day(day.date) == day)
    }

    @Test("newer, unknown, unreadable, and misnamed files are skipped and left untouched (V18)")
    func skipsWithoutTouching() async throws {
        let dir = try makeDirectory()
        try write(DayFile(date: "2026-10-01", timeZone: "UTC"), in: dir)
        let bad: [String: String] = [
            "2026-10-02": #"{"schemaVersion": 2, "date": "2026-10-02"}"#,
            "2026-10-03": #"{"date": "2026-10-03"}"#,
            "2026-10-04": "{ truncated",
            "2026-10-05": String(decoding: try DayFile(date: "2026-10-06", timeZone: "UTC").encoded(), as: UTF8.self),
        ]
        for (key, text) in bad {
            try Data(text.utf8).write(to: dir.appending(path: "\(key).json"))
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).sorted()

        let reader = HistoryReader(directory: dir)
        #expect(try await reader.days().map(\.date) == ["2026-10-01"])

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).sorted() == before)
        for (key, text) in bad {
            #expect(try Data(contentsOf: dir.appending(path: "\(key).json")) == Data(text.utf8))
        }
    }

    @Test("an unlistable history/ throws (V46 unreadable store)")
    func unlistableDirectoryThrows() async throws {
        let dir = try makeDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path(percentEncoded: false))
        }
        await #expect(throws: (any Error).self) {
            try await HistoryReader(directory: dir).dayKeys()
        }
    }

    @Test("default directory is history/ under the app's Application Support (I9)")
    func defaultDirectory() {
        #expect(HistoryReader.defaultDirectory.path(percentEncoded: false)
            .hasSuffix("Library/Application Support/AgentsUsageBar/history/"))
    }
}

import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func createFile(at url: URL, mtime: Date? = nil) throws {
    FileManager.default.createFile(atPath: url.path, contents: Data())
    if let mtime {
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }
}

@Suite("TranscriptDirectoryScanner")
struct TranscriptDirectoryScannerTests {

    @Test func scanRoots_findsJsonlFiles_recursively() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let fileA = sub.appendingPathComponent("a.jsonl")
        let fileB = sub.appendingPathComponent("b.jsonl")
        try createFile(at: fileA)
        try createFile(at: fileB)

        let scanner = TranscriptDirectoryScanner()
        let results = scanner.scanRoots([dir], modifiedSince: nil)

        let paths = results.map { $0.lastPathComponent }.sorted()
        #expect(paths.contains("a.jsonl"))
        #expect(paths.contains("b.jsonl"))
    }

    @Test func scanRoots_filtersByExtension() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let txt = dir.appendingPathComponent("notes.txt")
        let jsonl = dir.appendingPathComponent("data.jsonl")
        try createFile(at: txt)
        try createFile(at: jsonl)

        let scanner = TranscriptDirectoryScanner()
        let results = scanner.scanRoots([dir], modifiedSince: nil)

        let names = results.map { $0.lastPathComponent }
        #expect(names.contains("data.jsonl"))
        #expect(!names.contains("notes.txt"))
    }

    @Test func scanRoots_skipsHiddenFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let hidden = dir.appendingPathComponent(".hidden.jsonl")
        let visible = dir.appendingPathComponent("visible.jsonl")
        try createFile(at: hidden)
        try createFile(at: visible)

        let scanner = TranscriptDirectoryScanner()
        let results = scanner.scanRoots([dir], modifiedSince: nil)

        let names = results.map { $0.lastPathComponent }
        #expect(names.contains("visible.jsonl"))
        #expect(!names.contains(".hidden.jsonl"))
    }

    @Test func scanRoots_filtersByMtime() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Anchor: 2026-05-13T10:30 UTC
        let anchor = Date(timeIntervalSince1970: 1_747_129_800) // 10:30 UTC

        let fileA = dir.appendingPathComponent("a.jsonl")
        let fileB = dir.appendingPathComponent("b.jsonl")
        // A: 10:00 (before anchor)
        try createFile(at: fileA, mtime: anchor.addingTimeInterval(-1800))
        // B: 11:00 (after anchor)
        try createFile(at: fileB, mtime: anchor.addingTimeInterval(1800))

        let scanner = TranscriptDirectoryScanner()
        let results = scanner.scanRoots([dir], modifiedSince: anchor)

        let names = results.map { $0.lastPathComponent }
        // B is newer than anchor; A is older so filtered out
        #expect(names.contains("b.jsonl"))
        #expect(!names.contains("a.jsonl"))
    }

    @Test func scanRoots_missingRoot_returnsEmptyForThatRoot() throws {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let scanner = TranscriptDirectoryScanner()
        let results = scanner.scanRoots([nonexistent], modifiedSince: nil)
        #expect(results.isEmpty)
    }

    @Test func scanRoots_emptyRoots_returnsEmpty() throws {
        let scanner = TranscriptDirectoryScanner()
        let results = scanner.scanRoots([], modifiedSince: nil)
        #expect(results.isEmpty)
    }

    @Test func scanRoots_multipleRoots_aggregates() throws {
        let dir1 = try makeTempDir()
        let dir2 = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir1)
            try? FileManager.default.removeItem(at: dir2)
        }

        try createFile(at: dir1.appendingPathComponent("x.jsonl"))
        try createFile(at: dir2.appendingPathComponent("y.jsonl"))

        let scanner = TranscriptDirectoryScanner()
        let results = scanner.scanRoots([dir1, dir2], modifiedSince: nil)

        let names = results.map { $0.lastPathComponent }
        #expect(names.contains("x.jsonl"))
        #expect(names.contains("y.jsonl"))
        #expect(results.count == 2)
    }
}

import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Helpers

private func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func createDateDir(in root: URL, year: Int, month: Int, day: Int) throws -> URL {
    let dir = root
        .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func touchJsonl(in dir: URL, name: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data())
    return url
}

/// Builds a `Date` for `(year, month, day)` at noon local time using the current
/// calendar. Noon avoids ambiguous DST hours so `Calendar.current.startOfDay(for:)`
/// always lands on the intended civil date across any host timezone.
private func localNoon(year: Int, month: Int, day: Int, timeZone: TimeZone = .current) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    var comps = DateComponents()
    comps.year = year
    comps.month = month
    comps.day = day
    comps.hour = 12
    return cal.date(from: comps)!
}

@Suite("CodexRolloutScannerTests")
struct CodexRolloutScannerTests {

    // MARK: - Empty / smoke

    @Test func emptyRoot_returnsEmpty() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = CodexRolloutScanner(now: Date(), root: root)
        #expect(scanner.rolloutFiles().isEmpty)
    }

    @Test func missingRoot_returnsEmpty() throws {
        // Pass a root that does not exist on disk — must not throw, must return [].
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scanner = CodexRolloutScanner(now: Date(), root: nonexistent)
        #expect(scanner.rolloutFiles().isEmpty)
    }

    @Test func nilRoot_returnsEmpty() throws {
        let scanner = CodexRolloutScanner(now: Date(), root: nil)
        #expect(scanner.rolloutFiles().isEmpty)
    }

    // MARK: - Today / yesterday math

    @Test func todayOnly_returnsTodayFile() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Pin "now" to 2026-04-15 12:00 local — today.
        let now = localNoon(year: 2026, month: 4, day: 15)
        // G-04: scanner forces Gregorian for path components (Buddhist-locale
        // hosts return year=2569 from Calendar.current). Tests must match.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Calendar.current.timeZone
        let today = cal.dateComponents([.year, .month, .day], from: cal.startOfDay(for: now))

        let todayDir = try createDateDir(in: root, year: today.year!, month: today.month!, day: today.day!)
        _ = try touchJsonl(in: todayDir, name: "rollout-today-1.jsonl")

        let scanner = CodexRolloutScanner(now: now, root: root)
        let files = scanner.rolloutFiles()
        let names = files.map { $0.lastPathComponent }
        #expect(names.contains("rollout-today-1.jsonl"))
        #expect(files.count == 1)
    }

    @Test func todayAndYesterday_returnsBoth() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = localNoon(year: 2026, month: 4, day: 15)
        // G-04: scanner forces Gregorian for path components (Buddhist-locale
        // hosts return year=2569 from Calendar.current). Tests must match.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Calendar.current.timeZone
        let todayDate = cal.startOfDay(for: now)
        let yesterdayDate = cal.date(byAdding: .day, value: -1, to: todayDate)!

        let today = cal.dateComponents([.year, .month, .day], from: todayDate)
        let yesterday = cal.dateComponents([.year, .month, .day], from: yesterdayDate)

        let todayDir = try createDateDir(in: root, year: today.year!, month: today.month!, day: today.day!)
        let yesterdayDir = try createDateDir(in: root, year: yesterday.year!, month: yesterday.month!, day: yesterday.day!)
        _ = try touchJsonl(in: todayDir, name: "today.jsonl")
        _ = try touchJsonl(in: yesterdayDir, name: "yesterday.jsonl")

        let scanner = CodexRolloutScanner(now: now, root: root)
        let names = scanner.rolloutFiles().map { $0.lastPathComponent }.sorted()
        #expect(names == ["today.jsonl", "yesterday.jsonl"])
    }

    @Test func threeDaysOfFiles_returnsOnlyTodayAndYesterday() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = localNoon(year: 2026, month: 4, day: 15)
        // G-04: scanner forces Gregorian for path components (Buddhist-locale
        // hosts return year=2569 from Calendar.current). Tests must match.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Calendar.current.timeZone
        let todayDate = cal.startOfDay(for: now)
        let yesterdayDate = cal.date(byAdding: .day, value: -1, to: todayDate)!
        let twoDaysAgoDate = cal.date(byAdding: .day, value: -2, to: todayDate)!

        let today = cal.dateComponents([.year, .month, .day], from: todayDate)
        let yesterday = cal.dateComponents([.year, .month, .day], from: yesterdayDate)
        let twoDaysAgo = cal.dateComponents([.year, .month, .day], from: twoDaysAgoDate)

        let todayDir = try createDateDir(in: root, year: today.year!, month: today.month!, day: today.day!)
        let yesterdayDir = try createDateDir(in: root, year: yesterday.year!, month: yesterday.month!, day: yesterday.day!)
        let oldDir = try createDateDir(in: root, year: twoDaysAgo.year!, month: twoDaysAgo.month!, day: twoDaysAgo.day!)

        _ = try touchJsonl(in: todayDir, name: "today.jsonl")
        _ = try touchJsonl(in: yesterdayDir, name: "yesterday.jsonl")
        _ = try touchJsonl(in: oldDir, name: "older.jsonl")

        let scanner = CodexRolloutScanner(now: now, root: root)
        let names = scanner.rolloutFiles().map { $0.lastPathComponent }.sorted()
        #expect(names == ["today.jsonl", "yesterday.jsonl"])
        #expect(!names.contains("older.jsonl"))
    }

    @Test func missingYesterdayDir_returnsTodayOnly_doesNotThrow() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = localNoon(year: 2026, month: 4, day: 15)
        // G-04: scanner forces Gregorian for path components (Buddhist-locale
        // hosts return year=2569 from Calendar.current). Tests must match.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Calendar.current.timeZone
        let today = cal.dateComponents([.year, .month, .day], from: cal.startOfDay(for: now))

        // Only today exists; do NOT create yesterday's directory.
        let todayDir = try createDateDir(in: root, year: today.year!, month: today.month!, day: today.day!)
        _ = try touchJsonl(in: todayDir, name: "today.jsonl")

        let scanner = CodexRolloutScanner(now: now, root: root)
        let names = scanner.rolloutFiles().map { $0.lastPathComponent }
        #expect(names == ["today.jsonl"])
    }

    // MARK: - DST and leap-day

    @Test func dstSpringForward_yesterdayResolvesPreDST_PT() throws {
        // 2026-03-08 02:00 PT is the spring-forward boundary; yesterday from
        // 2026-03-08 12:00 PT must be 2026-03-07 regardless of the missing hour.
        let pt = TimeZone(identifier: "America/Los_Angeles")!
        let now = localNoon(year: 2026, month: 3, day: 8, timeZone: pt)

        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Yesterday in PT = 2026-03-07.
        let yesterdayDir = try createDateDir(in: root, year: 2026, month: 3, day: 7)
        _ = try touchJsonl(in: yesterdayDir, name: "y.jsonl")

        // Provide an explicit PT calendar via injection so the test is host-tz independent.
        var ptCal = Calendar(identifier: .gregorian)
        ptCal.timeZone = pt

        let scanner = CodexRolloutScanner(now: now, calendar: ptCal, root: root)
        let names = scanner.rolloutFiles().map { $0.lastPathComponent }
        #expect(names.contains("y.jsonl"))
    }

    @Test func leapDay_yesterdayFrom_2028_02_29_is_2028_02_28() throws {
        let utc = TimeZone(identifier: "UTC")!
        let now = localNoon(year: 2028, month: 2, day: 29, timeZone: utc)

        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Yesterday must be 2028/02/28 — not 2028/03/00 (string math bug catch).
        let yesterdayDir = try createDateDir(in: root, year: 2028, month: 2, day: 28)
        _ = try touchJsonl(in: yesterdayDir, name: "leap-y.jsonl")

        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = utc

        let scanner = CodexRolloutScanner(now: now, calendar: utcCal, root: root)
        let names = scanner.rolloutFiles().map { $0.lastPathComponent }
        #expect(names.contains("leap-y.jsonl"))
    }

    // MARK: - Symlink canonicalisation (STATE #44 pattern)

    @Test func returnedURLs_areSymlinkCanonicalised() throws {
        // On macOS, /var is a symlink to /private/var. Creating files via FileManager
        // temporaryDirectory + appendingPathComponent often yields /var/folders/...,
        // but the canonical form is /private/var/folders/.... Assert that returned
        // URLs canonicalise so downstream cache keys remain stable.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = localNoon(year: 2026, month: 4, day: 15)
        // G-04: scanner forces Gregorian for path components (Buddhist-locale
        // hosts return year=2569 from Calendar.current). Tests must match.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Calendar.current.timeZone
        let today = cal.dateComponents([.year, .month, .day], from: cal.startOfDay(for: now))

        let todayDir = try createDateDir(in: root, year: today.year!, month: today.month!, day: today.day!)
        let realFile = try touchJsonl(in: todayDir, name: "real.jsonl")

        let scanner = CodexRolloutScanner(now: now, root: root)
        let files = scanner.rolloutFiles()
        #expect(files.count == 1)

        let returned = try #require(files.first)
        let canonicalReal = realFile.resolvingSymlinksInPath()
        // The scanner's returned URL must already equal the symlink-canonical form.
        #expect(returned.path == canonicalReal.path)
        // Belt-and-suspenders: applying resolvingSymlinksInPath again must be a no-op.
        #expect(returned.resolvingSymlinksInPath().path == returned.path)
    }

    // MARK: - Filtering

    @Test func filtersByExtension_nonJsonlIgnored() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = localNoon(year: 2026, month: 4, day: 15)
        // G-04: scanner forces Gregorian for path components (Buddhist-locale
        // hosts return year=2569 from Calendar.current). Tests must match.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Calendar.current.timeZone
        let today = cal.dateComponents([.year, .month, .day], from: cal.startOfDay(for: now))
        let todayDir = try createDateDir(in: root, year: today.year!, month: today.month!, day: today.day!)

        _ = try touchJsonl(in: todayDir, name: "good.jsonl")
        // Drop a non-jsonl peer.
        let other = todayDir.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: other.path, contents: Data())

        let scanner = CodexRolloutScanner(now: now, root: root)
        let names = scanner.rolloutFiles().map { $0.lastPathComponent }
        #expect(names == ["good.jsonl"])
    }

    @Test func skipsHiddenFiles() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = localNoon(year: 2026, month: 4, day: 15)
        // G-04: scanner forces Gregorian for path components (Buddhist-locale
        // hosts return year=2569 from Calendar.current). Tests must match.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Calendar.current.timeZone
        let today = cal.dateComponents([.year, .month, .day], from: cal.startOfDay(for: now))
        let todayDir = try createDateDir(in: root, year: today.year!, month: today.month!, day: today.day!)

        _ = try touchJsonl(in: todayDir, name: "visible.jsonl")
        _ = try touchJsonl(in: todayDir, name: ".hidden.jsonl")

        let scanner = CodexRolloutScanner(now: now, root: root)
        let names = scanner.rolloutFiles().map { $0.lastPathComponent }
        #expect(names.contains("visible.jsonl"))
        #expect(!names.contains(".hidden.jsonl"))
    }
}

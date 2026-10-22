import Testing
import Foundation
@testable import AgentsUsageBar

/// `aub stats` text on generated history (SPEC V42–V46, C3). Goldens live in `Golden/`.
///
/// Re-record (only when an output change is intended):
/// `TEST_RUNNER_AUB_RECORD_GOLDEN=1 xcodebuild test … -only-testing:AgentsUsageBarTests/StatsTextRendererTests`
@Suite("aub stats text")
struct StatsTextRendererTests {

    static let today = "2026-03-14"
    static let history = SyntheticHistory.days(endingAt: today, count: 90)

    private func range(days: Int? = nil, since: String? = nil, until: String? = nil) throws -> StatsRange {
        try StatsRange.resolve(today: Self.today, days: days, since: since, until: until).get()
    }

    private func summary(_ range: StatsRange, includeLocal: Bool = false, color: Bool = false) -> String {
        StatsTextRenderer.renderSummary(Self.history, range: range, includeLocal: includeLocal, color: color)
    }

    private func drill(_ id: String, _ range: StatsRange, color: Bool = false) -> String {
        StatsTextRenderer.renderProvider(Self.history, id: ProviderID(rawValue: id), range: range, color: color)
    }

    // MARK: - Goldens

    @Test("goldens", arguments: [
        "stats-summary.txt", "stats-summary-color.txt", "stats-summary-all.txt", "stats-summary-90.txt",
        "stats-claude.txt", "stats-codex.txt", "stats-openrouter.txt", "stats-ollama.txt",
    ])
    func golden(name: String) throws {
        let output = switch name {
        case "stats-summary.txt": summary(try range())
        case "stats-summary-color.txt": summary(try range(), color: true)
        case "stats-summary-all.txt": summary(try range(), includeLocal: true)
        case "stats-summary-90.txt": summary(try range(days: 90))
        case "stats-claude.txt": drill("claude", try range())
        case "stats-codex.txt": drill("codex", try range(days: 7))
        case "stats-openrouter.txt": drill("openrouter", try range(days: 7))
        default: drill("ollama", try range(days: 7))
        }
        try GoldenFile.assert(output, name)
    }

    // MARK: - Behaviour

    @Test("summary header names the range and the open day; today is the last trend character (V45)")
    func headerAndOpenDay() throws {
        let lines = summary(try range()).split(separator: "\n")
        #expect(lines[0] == "2026-03-01 – 2026-03-14 · 14 days (today open)")
        let ended = summary(try range(until: "2026-03-10")).split(separator: "\n")
        #expect(ended[0] == "2026-02-25 – 2026-03-10 · 14 days")
    }

    @Test("total row is metered spend only; subscription value never counts (V26, V42)")
    func totalIsMeteredSpendOnly() throws {
        let r = try range()
        let records = Self.history.filter { r.keys.contains($0.date) }.flatMap(\.records)
        let openRouter = records.filter { $0.provider.rawValue == "openrouter" }
            .reduce(Decimal(0)) { $0 + ($1.costUSD?.amount ?? 0) }
        let total = summary(r).split(separator: "\n").first { $0.hasPrefix("total") }!
        // Codex is mixed with no per-account cost, so its spend is unknown and the total is incomplete.
        #expect(total.hasSuffix(CLIFormat.usd(openRouter) + "!"))
        #expect(!total.contains("~"))
    }

    @Test("subscription spend cell shows the plan, mixed shows spend plus +plan (V43)")
    func spendCells() throws {
        let text = summary(try range())
        let claude = text.split(separator: "\n").first { $0.hasPrefix("Claude") }!
        #expect(claude.contains("max/pro"))
        #expect(!claude.contains("$"))
        let codex = text.split(separator: "\n").first { $0.hasPrefix("Codex") }!
        #expect(codex.contains("?! +plus"))
    }

    @Test("local runtimes are hidden unless all, which shows presence (V44)")
    func localHidden() throws {
        #expect(!summary(try range()).contains("Ollama"))
        let all = summary(try range(), includeLocal: true)
        #expect(all.contains("used 14/14 days"))
    }

    @Test("a gap is a dot in the trend, never drawn low, and the legend lists only markers present (V45)")
    func gapsAndLegend() throws {
        let claude = summary(try range()).split(separator: "\n").first { $0.hasPrefix("Claude") }!
        #expect(claude.contains("·"))
        // The summary shows no estimated amount: Claude shows its plan, Codex spend is unknown.
        // Every 5th Codex day is backfilled with no quota: recorded, so `?`, not a gap (V64).
        let codex = summary(try range()).split(separator: "\n").first { $0.hasPrefix("Codex") }!
        #expect(codex.contains("?"))
        #expect(!codex.contains("·"))
        let legend = summary(try range()).split(separator: "\n").last!
        #expect(legend == "· gap  ? no value  ! incomplete")
        #expect(drill("claude", try range()).hasSuffix("~ estimated  · gap  ! incomplete\n"))
        let openRouter = drill("openrouter", try range(days: 3))
        #expect(!openRouter.contains("estimated"))
        #expect(!openRouter.contains("gap"))
    }

    @Test("a recorded day with no value is `?`, a missing record is a gap; mixed buckets are incomplete (V64)")
    func noValueVersusGap() {
        let metered = [DayAccount(key: "default", label: "default", billingModel: .metered)]
        let subscription = [DayAccount(key: "demo", label: "demo", billingModel: .subscription, plan: "pro")]
        func record(_ accounts: [DayAccount], cost: Int? = nil, peak: Double? = nil, origin: RecordOrigin = .observed) -> DayRecord {
            DayRecord(provider: ProviderID(rawValue: "demo"), costUSD: cost.map { Money(Decimal($0)) },
                      quota: peak.map { ["5h": QuotaDay(peak: $0, endOfDay: $0)] } ?? [:],
                      accounts: accounts, origin: origin)
        }

        // Metered: reported cost, nil cost, no record.
        let spend = ProviderStats(id: ProviderID(rawValue: "demo"),
                                  records: [record(metered, cost: 2), record(metered), nil])
        #expect(spend.kind == .metered)
        #expect(spend.trend(bucketSize: 1) == [.value(2), .noValue, .gap])
        #expect(spend.trend(bucketSize: 3) == [.incomplete])

        // Subscription: a peak, a backfilled day with no quota (V30), two more no-value days, no record.
        let backfilled = record(subscription, origin: .backfilled)
        let peaks = ProviderStats(id: ProviderID(rawValue: "demo"),
                                  records: [record(subscription, peak: 0.5), backfilled, backfilled, backfilled, nil])
        #expect(peaks.kind == .subscription)
        #expect(peaks.trend(bucketSize: 1) == [.value(0.5), .noValue, .noValue, .noValue, .gap])
        // Buckets end at the newest key: [peak] [?, ?] [?, gap].
        #expect(peaks.trend(bucketSize: 2) == [.value(0.5), .noValue, .incomplete])
        #expect(peaks.seenDays == 4)

        let legend = StatsTextRenderer.Legend(noValue: true).line(color: false)
        #expect(legend == ["? no value"])
    }

    @Test("beyond 30 days the trend is equal buckets named in the header; a gap marks its bucket (V44)")
    func buckets() throws {
        let text = summary(try range(days: 90))
        #expect(text.split(separator: "\n")[0].hasSuffix("· trend 1 char = 3 days"))
        let claude = text.split(separator: "\n").first { $0.hasPrefix("Claude") }!
        let trend = claude.split(separator: "%").last!
        #expect(trend.count == 30)
        // Every 7th Claude day is a gap, so most 3-day buckets are incomplete, none drawn low.
        #expect(trend.contains("!"))
    }

    @Test("drill-down flags backfilled days and today (V44, V45)")
    func drillMarkers() throws {
        let codex = drill("codex", try range(days: 7))
        #expect(codex.contains("backfilled"))
        #expect(codex.split(separator: "\n").contains { $0.hasPrefix(Self.today) && $0.hasSuffix("open") })
        let claude = drill("claude", try range())
        #expect(claude.contains("80% 5h"))
    }

    @Test("colour drops cleanly: plain output has no ANSI (V46)")
    func noAnsi() throws {
        #expect(!summary(try range()).contains("\u{001B}"))
        #expect(summary(try range(), color: true).contains("\u{001B}"))
    }

    // MARK: - Range

    @Test("range flags resolve against today (V44)")
    func ranges() throws {
        #expect(try range().keys.count == 14)
        #expect(try range(days: 3).keys == ["2026-03-12", "2026-03-13", "2026-03-14"])
        #expect(try range(since: "2026-02-27", until: "2026-03-02").keys
                == ["2026-02-27", "2026-02-28", "2026-03-01", "2026-03-02"])
        #expect(try range(days: 2, since: "2026-03-01").keys == ["2026-03-01", "2026-03-02"])
        #expect(try range(since: "2026-03-13", until: "2026-04-01").keys == ["2026-03-13", "2026-03-14"])
        #expect(StatsRange.resolve(today: Self.today, days: nil, since: "2026-03-05", until: "2026-03-01")
                == .failure(.emptyRange("2026-03-05", "2026-03-01")))
        #expect(StatsRange.resolve(today: Self.today, days: 3, since: "2026-03-01", until: "2026-03-05")
                == .failure(.unexpectedArgument("--days")))
        #expect(try range(days: 30).bucketSize == 1)
        #expect(try range(days: 31).bucketSize == 2)
        #expect(!StatsRange.isDayKey("2026-02-30"))
        #expect(StatsRange.isDayKey("2024-02-29"))
    }

    // MARK: - Edge output

    @Test("no history prints one line and exits 0; nothing is created (V19, V46)")
    func noHistory() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        let result = try await AUBCommand.stats(
            .init(noColor: true), reader: HistoryReader(directory: dir), owner: DayKeyOwner())
        #expect(result == ("No history yet. The app records from first launch; backfill runs in the background\n", 0))
        #expect(!FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
    }

    @Test("an unreadable store is an error with exit 1 (V46)")
    func unreadable() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try Data("not a directory".utf8).write(to: file)
        let result = try await AUBCommand.stats(
            .init(noColor: true), reader: HistoryReader(directory: file), owner: DayKeyOwner())
        #expect(result.code == 1)
        #expect(result.text.hasPrefix("error: cannot read usage history"))
    }

    @Test("today never goes behind the newest day file (V4)")
    func todayFromNewestFile() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try SyntheticHistory.write(SyntheticHistory.days(endingAt: Self.today, count: 3), to: dir)
        let behind = ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z")!
        let owner = DayKeyOwner(clock: VirtualClock(fixed: behind), timeZone: TimeZone(identifier: "UTC")!)
        let result = try await AUBCommand.stats(
            .init(filter: .one(.openrouter), days: 3, noColor: true), reader: HistoryReader(directory: dir), owner: owner)
        #expect(result.code == 0)
        #expect(result.text.hasPrefix("OpenRouter · 2026-03-12 – 2026-03-14 · 3 days (today open)"))
    }
}

/// Golden files next to the CLI tests, recorded with `AUB_RECORD_GOLDEN=1`.
enum GoldenFile {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")

    static func assert(_ actual: String, _ name: String) throws {
        let url = directory.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["AUB_RECORD_GOLDEN"] == "1" {
            try Data(actual.utf8).write(to: url)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(actual == expected, "golden mismatch: \(name)")
    }
}

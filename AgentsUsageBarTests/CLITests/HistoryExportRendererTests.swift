import Testing
import Foundation
@testable import AgentsUsageBar

/// `aub stats --json` and `--csv` on generated history (SPEC V26, V47–V49, C3). Goldens live
/// in `Golden/`; re-record as `StatsTextRendererTests` describes.
@Suite("aub stats export")
struct HistoryExportRendererTests {

    static let today = "2026-03-14"
    /// Seven days: a Claude gap on 03-14 (index 6), a backfilled Codex day on 03-12 (index 4),
    /// and band events.
    static let history = SyntheticHistory.days(endingAt: today, count: 7)
    static let exportedAt = Date(timeIntervalSince1970: 1_773_500_000)

    private func scope(days: Int? = 7, provider: ProviderID? = nil,
                       isEnabled: @escaping @Sendable (ProviderID) -> Bool = { _ in true }) throws -> HistoryExportRenderer.Scope {
        let range = try StatsRange.resolve(today: Self.today, days: days, since: nil, until: nil).get()
        return .init(range: range, provider: provider, isEnabled: isEnabled)
    }

    private func json(_ scope: HistoryExportRenderer.Scope) throws -> [String: Any] {
        let text = try HistoryExportRenderer.json(Self.history, scope: scope, exportedAt: Self.exportedAt)
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    private func days(_ export: [String: Any]) -> [[String: Any]] { export["days"] as! [[String: Any]] }

    private func record(_ day: [String: Any], _ provider: String) -> [String: Any]? {
        (day["records"] as! [[String: Any]]).first { $0["provider"] as? String == provider }
    }

    // MARK: - Goldens

    @Test("goldens", arguments: ["export.json", "export-days.csv", "export-accounts.csv", "export-events.csv", "export-quota.csv"])
    func golden(name: String) throws {
        let s = try scope(days: 3)
        let output = switch name {
        case "export.json": try HistoryExportRenderer.json(Self.history, scope: s, exportedAt: Self.exportedAt)
        case "export-days.csv": HistoryExportRenderer.csv(Self.history, scope: s, table: .days)
        case "export-accounts.csv": HistoryExportRenderer.csv(Self.history, scope: s, table: .accounts)
        case "export-events.csv": HistoryExportRenderer.csv(Self.history, scope: s, table: .events)
        default: HistoryExportRenderer.csv(Self.history, scope: s, table: .quota)
        }
        try GoldenFile.assert(output, name)
    }

    // MARK: - JSON (V48)

    @Test("top level is schemaVersion 1, exportedAt, range, days; nothing private")
    func jsonTopLevel() throws {
        let export = try json(try scope())
        #expect(Set(export.keys) == ["schemaVersion", "exportedAt", "range", "days"])
        #expect(export["schemaVersion"] as? Int == 1)
        #expect(export["range"] as? [String: String] == ["from": "2026-03-08", "to": "2026-03-14"])
        let text = try HistoryExportRenderer.json(Self.history, scope: try scope(), exportedAt: Self.exportedAt)
        #expect(!text.contains("backfillChecked"))
        #expect(!text.contains("salt"))
        #expect(!text.contains("budget"))
    }

    @Test("today is included with sealed false; earlier days are sealed")
    func todayUnsealed() throws {
        let all = days(try json(try scope()))
        #expect(all.map { $0["date"] as! String }.last == Self.today)
        #expect(all.last?["sealed"] as? Bool == false)
        #expect(all.dropLast().allSatisfy { $0["sealed"] as? Bool == true })
    }

    @Test("subscription value exports as valueUSD, never as spend (V26)")
    func valueIsNotSpend() throws {
        let day = days(try json(try scope()))[0]
        let claude = try #require(record(day, "claude"))
        #expect(claude["costUSD"] is NSNull)
        #expect(claude["valueUSD"] as? String == "5")
        let openrouter = try #require(record(day, "openrouter"))
        #expect(openrouter["costUSD"] as? String != nil)
        #expect(openrouter["valueUSD"] is NSNull)
    }

    @Test("unknown values are null, never 0; money is a decimal string")
    func unknownIsNull() throws {
        let day = days(try json(try scope()))[0]
        let ollama = try #require(record(day, "ollama"))
        #expect(ollama["tokens"] is NSNull)
        #expect(ollama["costUSD"] is NSNull)
        #expect(ollama["balanceUSD"] is NSNull)
        let openrouter = try #require(record(day, "openrouter"))
        #expect(openrouter["balanceUSD"] is String)
    }

    @Test("accounts export key, label, billing model, and plan only")
    func accountFields() throws {
        let claude = try #require(record(days(try json(try scope()))[0], "claude"))
        let accounts = claude["accounts"] as! [[String: Any]]
        #expect(accounts.allSatisfy { Set($0.keys) == ["key", "label", "billingModel", "plan"] })
    }

    @Test("gaps list enabled providers with no record that day")
    func gaps() throws {
        let last = days(try json(try scope())).last!
        #expect(last["gaps"] as? [String] == ["claude"])
        let disabled = days(try json(try scope(isEnabled: { $0 != .claude }))).last!
        #expect(disabled["gaps"] as? [String] == [])
    }

    @Test("a range key without a file has a null zone and every seen provider as a gap")
    func missingDayFile() throws {
        let range = try StatsRange.resolve(today: "2026-03-15", days: 3, since: nil, until: nil).get()
        let export = try HistoryExportRenderer.json(Self.history, scope: .init(range: range), exportedAt: Self.exportedAt)
        let all = days(try JSONSerialization.jsonObject(with: Data(export.utf8)) as! [String: Any])
        #expect(all.last?["timeZone"] is NSNull)
        #expect(all.last?["gaps"] as? [String] == ["claude", "codex", "ollama", "openrouter"])
    }

    @Test("--provider narrows records, events, and gaps to one provider")
    func providerScope() throws {
        let all = days(try json(try scope(provider: .claude)))
        #expect(all.allSatisfy { ($0["records"] as! [[String: Any]]).allSatisfy { $0["provider"] as? String == "claude" } })
        #expect(all.last?["gaps"] as? [String] == ["claude"])
        let codex = days(try json(try scope(provider: .codex)))
        #expect(codex.allSatisfy { ($0["events"] as! [Any]).isEmpty })
    }

    @Test("default export range is every retained day (V47)")
    func defaultRangeIsAllRetained() throws {
        let range = try StatsRange.resolve(today: Self.today, days: nil, since: nil, until: nil, oldest: "2026-03-08").get()
        #expect(range.keys.first == "2026-03-08")
        #expect(range.keys.count == 7)
        let narrowed = try StatsRange.resolve(today: Self.today, days: 2, since: nil, until: nil, oldest: "2026-03-08").get()
        #expect(narrowed.keys == ["2026-03-13", "2026-03-14"])
    }

    // MARK: - CSV (V49)

    @Test("every table starts with its fixed header")
    func headers() throws {
        let s = try scope()
        for table in HistoryExportRenderer.CSVTable.allCases {
            let header = HistoryExportRenderer.csv(Self.history, scope: s, table: table).split(separator: "\n")[0]
            #expect(header == HistoryExportRenderer.columns(table).joined(separator: ","))
        }
        #expect(HistoryExportRenderer.columns(.days) == [
            "date", "provider", "tokens", "costUSD", "valueUSD", "costEstimated", "balanceUSD",
            "billingModel", "origin", "sealed", "firstSeen", "lastSeen",
        ])
    }

    @Test("a gap is a missing row; unknown is an empty cell; money is a plain number")
    func csvCells() throws {
        let rows = HistoryExportRenderer.csv(Self.history, scope: try scope(), table: .days)
            .split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        #expect(!rows.contains { $0[0] == Self.today && $0[1] == "claude" })
        let ollama = try #require(rows.first { $0[1] == "ollama" })
        #expect(ollama[2] == "" && ollama[3] == "" && ollama[6] == "")
        #expect(ollama[7] == "local")
        let claude = try #require(rows.first { $0[1] == "claude" })
        #expect(claude[3] == "" && claude[4] == "5")
        let codex = try #require(rows.first { $0[1] == "codex" })
        #expect(codex[7] == "mixed")
        #expect(rows.last?[9] == "false")
    }

    @Test("quota table: one row per provider, account, and window")
    func quotaRows() throws {
        let rows = HistoryExportRenderer.csv(Self.history, scope: try scope(days: 1, provider: .codex), table: .quota)
            .split(separator: "\n")
        #expect(rows.count == 2)
        #expect(rows[1].hasPrefix("2026-03-14,codex,,5h,0.5,,0.25"))
    }

    @Test("fields with commas or quotes are quoted")
    func escaping() throws {
        var day = Self.history[0]
        day.records = [DayRecord(provider: .claude, accounts: [
            DayAccount(key: "a,b", label: "say \"hi\"", billingModel: .subscription),
        ], origin: .observed)]
        let range = try StatsRange.resolve(today: day.date, days: 1, since: nil, until: nil).get()
        let csv = HistoryExportRenderer.csv([day], scope: .init(range: range), table: .accounts)
        #expect(csv.split(separator: "\n")[1] == "\(day.date),claude,\"a,b\",\"say \"\"hi\"\"\",subscription,")
    }

    // MARK: - Command

    @Test("aub stats --json on an empty store is a valid export, exit 0")
    func emptyStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aub-export-\(UUID().uuidString)")
        let opts = AUBCommand.StatsOptions(format: .json)
        let result = try await AUBCommand.stats(opts, reader: HistoryReader(directory: dir), owner: DayKeyOwner(), now: Self.exportedAt)
        #expect(result.code == 0)
        let export = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as! [String: Any]
        #expect(export["schemaVersion"] as? Int == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
    }

    @Test("aub stats --csv reads every retained day from disk")
    func csvFromDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aub-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try SyntheticHistory.write(Self.history, to: dir)
        let result = try await AUBCommand.stats(
            .init(format: .csv(.days)), reader: HistoryReader(directory: dir), owner: DayKeyOwner(), now: Self.exportedAt)
        let dates = Set(result.text.split(separator: "\n").dropFirst().map { $0.prefix(10) })
        #expect(dates.count == 7)
    }
}

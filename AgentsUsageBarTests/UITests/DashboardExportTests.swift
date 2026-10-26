import Foundation
import Testing
@testable import AgentsUsageBar

/// SPEC V47, V57 — dashboard Export… uses the `aub stats` renderer on the current scope.
@Suite("Dashboard export")
@MainActor
struct DashboardExportTests {
    private static let today = "2026-10-25"
    /// 2026-10-06 through today: more than the 14-day range, so Calendar's scope is wider.
    private static let history = SyntheticHistory.days(endingAt: today, count: 20)
    private static let exportedAt = Date(timeIntervalSince1970: 1_793_000_000)
    private static let noon = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!

    private func dayKeys() -> DayKeyOwner {
        DayKeyOwner(clock: VirtualClock(fixed: Self.noon), timeZone: TimeZone(identifier: "UTC")!)
    }

    /// A loaded model over `history` written to a scratch directory.
    private func loaded(_ route: DashboardRoute = DashboardRoute()) async throws -> (DashboardModel, HistoryReader, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dashboard-export-\(UUID().uuidString)")
        try SyntheticHistory.write(Self.history, to: directory)
        let reader = HistoryReader(directory: directory)
        let model = DashboardModel(route: route, reader: reader, dayKeys: dayKeys(), order: [])
        await model.load()
        return (model, reader, directory)
    }

    private func cli(_ opts: AUBCommand.StatsOptions, reader: HistoryReader) async throws -> String {
        let result = try await AUBCommand.stats(opts, reader: reader, owner: dayKeys(), now: Self.exportedAt)
        #expect(result.code == 0)
        return result.text
    }

    @Test("each section exports its own scope (V57)")
    func scopes() async throws {
        let (model, _, directory) = try await loaded()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.excluded = [.codex]

        let overview = model.exportScope(isEnabled: { _ in true })
        #expect(overview.range.keys.count == 14)
        #expect(overview.range.keys.last == Self.today)
        #expect(overview.provider == nil)
        #expect(overview.excluded == [.codex])

        model.show(DashboardRoute(provider: .claude))
        model.range = .days7
        let detail = model.exportScope(isEnabled: { _ in true })
        #expect(detail.range.keys.count == 7)
        #expect(detail.provider == .claude)
        #expect(detail.excluded.isEmpty)

        model.show(DashboardRoute(day: "2026-10-10"))
        let calendar = model.exportScope(isEnabled: { _ in true })
        #expect(calendar.range.keys == Self.history.map(\.date))
        #expect(calendar.provider == nil)
        #expect(calendar.excluded.isEmpty)
    }

    @Test("bytes match `aub stats` for the same scope (V47)")
    func bytesMatchCLI() async throws {
        let (model, reader, directory) = try await loaded()
        defer { try? FileManager.default.removeItem(at: directory) }

        let overview = try model.export(.json, isEnabled: { _ in true }, exportedAt: Self.exportedAt)
        #expect(overview == (try await cli(.init(days: 14, format: .json), reader: reader)))

        model.show(DashboardRoute(provider: .codex))
        model.range = .days30
        for table in HistoryExportRenderer.CSVTable.allCases {
            let detail = try model.export(.csv(table), isEnabled: { _ in true }, exportedAt: Self.exportedAt)
            #expect(detail == (try await cli(.init(filter: .one(.codex), days: 30, format: .csv(table)), reader: reader)))
        }

        model.show(DashboardRoute(day: Self.today))
        let calendar = try model.export(.json, isEnabled: { _ in true }, exportedAt: Self.exportedAt)
        #expect(calendar == (try await cli(.init(format: .json), reader: reader)))
    }

    @Test("chips switched off drop those providers' records, events, and gaps (V57)")
    func chipsExclude() async throws {
        let (model, _, directory) = try await loaded()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.excluded = [.claude]

        let csv = try model.export(.csv(.days), isEnabled: { _ in true }, exportedAt: Self.exportedAt)
        #expect(!csv.contains(",claude,"))
        #expect(csv.contains(",codex,"))
        let events = try model.export(.csv(.events), isEnabled: { _ in true }, exportedAt: Self.exportedAt)
        #expect(!events.contains(",claude,"))
        let json = try model.export(.json, isEnabled: { _ in true }, exportedAt: Self.exportedAt)
        #expect(!json.contains("\"claude\""))
    }

    @Test("format names carry the range and table")
    func fileNames() {
        let range = StatsRange(keys: ["2026-10-01", "2026-10-02"], today: "2026-10-02")
        #expect(DashboardExportFormat.json.fileName(range) == "aub-usage-2026-10-01_2026-10-02.json")
        #expect(DashboardExportFormat.csv(.events).fileName(range) == "aub-usage-2026-10-01_2026-10-02-events.csv")
        #expect(DashboardExportFormat.allCases.count == 1 + HistoryExportRenderer.CSVTable.allCases.count)
    }
}

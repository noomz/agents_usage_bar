import Foundation
import Testing
@testable import AgentsUsageBar

/// `compact` CLI theme (SPEC V7–V23). Goldens render `CLIReportFixture` with
/// the header clock pinned to UTC. Re-record with `TEST_RUNNER_AUB_RECORD_GOLDEN=1`.
@Suite("Compact text renderer")
struct CompactTextRendererTests {

    static let utc = TimeZone(identifier: "UTC")!

    static func render(
        _ report: UsageReport = CLIReportFixture.rich(),
        view: CLIView = .usage,
        color: Bool = false,
        width: Int? = nil
    ) -> String {
        CompactTextRenderer.render(report, view: view, color: color, width: width, timeZone: utc)
    }

    // MARK: - Goldens

    @Test("usage, base width (pipes)")
    func usageBase() throws {
        try assertGolden(Self.render(), "compact-usage.txt")
    }

    @Test("usage, colour")
    func usageColor() throws {
        try assertGolden(Self.render(color: true), "compact-usage-color.txt")
    }

    @Test("usage, narrow 60 columns: bar shrinks, then names truncate")
    func usageNarrow() throws {
        try assertGolden(Self.render(width: 60), "compact-usage-60.txt")
    }

    @Test("usage, wide 110 columns: names widen, then bar up to 20")
    func usageWide() throws {
        try assertGolden(Self.render(width: 110), "compact-usage-110.txt")
    }

    @Test("quota view")
    func quota() throws {
        try assertGolden(Self.render(view: .quota), "compact-quota.txt")
    }

    @Test("single provider: header covers only the shown provider")
    func single() throws {
        let report = UsageReport(asOf: CLIReportFixture.asOf, source: .cached, providers: [CLIReportFixture.claude()])
        try assertGolden(Self.render(report), "compact-single-claude.txt")
    }

    @Test("empty cached report")
    func emptyCached() throws {
        let report = UsageReport(asOf: CLIReportFixture.asOf, source: .cached, providers: [])
        try assertGolden(Self.render(report), "compact-empty-cached.txt")
    }

    // MARK: - Rules

    @Test("empty live report says no providers enabled")
    func emptyLive() {
        let report = UsageReport(asOf: CLIReportFixture.asOf, source: .live, providers: [])
        let lines = Self.render(report).split(separator: "\n").map(String.init)
        #expect(lines == [
            "today $0.00 spent · 0 tok · 05:20",
            "0 at ≥80% · 0 at 50–79% · 0 unavailable",
            "no providers enabled",
        ])
    }

    @Test("Gemini model window labels are shortened (V11)", arguments: [
        ("gemini-2.5-pro", "2.5-pro"),
        ("gemini-2.5-flash", "2.5-flash"),
        ("gemini-2.5-flash-lite", "2.5-lite"),
        ("custom-model", "custom-model"),
        ("gemini-", "gemini-"),
    ])
    func geminiShortLabel(model: String, expected: String) {
        #expect(CompactTextRenderer.shortGeminiModel(model) == expected)
    }

    @Test("all providers disabled still says no providers enabled (V22)")
    func allDisabled() {
        var p = CLIReportFixture.codex()
        p.status = .disabled
        let report = UsageReport(asOf: CLIReportFixture.asOf, source: .live, providers: [p])
        #expect(Self.render(report).split(separator: "\n").last == "no providers enabled")
    }

    @Test("quota view keeps a Claude account with no windows as a no-limit row")
    func claudeAccountNoWindows() {
        var p = CLIReportFixture.claude()
        let snap = p.snapshot!
        p.snapshot = UsageSnapshot(
            providerID: .claude, asOf: snap.asOf, tokensToday: 0, costTodayUSD: nil,
            balanceUSD: nil, quota: nil, raw: [:], quotaWindows: nil,
            accounts: [.init(name: "solo", costTodayUSD: nil, quota: nil, quotaWindows: nil)]
        )
        let report = UsageReport(asOf: CLIReportFixture.asOf, source: .live, providers: [p])
        let row = Self.render(report, view: .quota).split(separator: "\n").first { $0.contains("solo") }
        #expect(row?.contains("no limit") == true)
    }

    @Test("header counts each account row and every ! row")
    func headerCounts() {
        let lines = Self.render().split(separator: "\n").map(String.init)
        #expect(lines[0] == "today $273.93 spent · 233.6M tok · 05:20")
        // ≥80: OpenRouter 94. 50–79: Codex 69, Ollama Cloud 62. !: Gemini (degraded, under its bar) + Grok.
        #expect(lines[1] == "1 at ≥80% · 2 at 50–79% · 2 unavailable")
    }

    @Test("rows follow known-provider order, never severity")
    func order() {
        let text = Self.render()
        let names = ["OpenRouter", "Claude", "Codex", "Gemini", "Grok", "local"]
        let positions = names.map { text.range(of: $0)!.lowerBound }
        #expect(positions == positions.sorted())
    }

    @Test("codex: header spend, primary bars, ● on the highest, failed child unavailable")
    func codexMultiLoginRows() throws {
        let now = CLIReportFixture.asOf
        let plusReset = now.addingTimeInterval(2 * 3600 + 50 * 60)
        let teamReset = now.addingTimeInterval(4 * 3600)
        let report = UsageReport(asOf: now, source: .live, providers: [
            multiCodexReport(
                cost: "0.07",
                accounts: [
                    codexAccount("team", primary: 0.80, primaryReset: teamReset, secondary: 0.10),
                    codexAccount("plus", primary: 0.20, primaryReset: plusReset, secondary: 0.90),
                    codexAccount("guest", primary: nil, primaryReset: nil, secondary: nil),
                ]
            ),
        ])

        let usage = Self.render(report).split(separator: "\n").map(String.init)
        #expect(usage[1] == "1 at ≥80% · 0 at 50–79% · 1 unavailable")
        let header = try #require(usage.first { $0.contains("Codex") && !$0.contains("plus") && !$0.contains("team") })
        #expect(header.hasSuffix("$0.07 spent"))
        #expect(!header.contains("%"))
        let plus = try #require(usage.first { $0.contains("plus") })
        #expect(plus.hasPrefix("    plus "))
        #expect(plus.contains("20%"))
        #expect(plus.contains("5h"))
        #expect(plus.contains("↻ 2h 50m"))
        #expect(!plus.contains("90%"))
        #expect(!plus.contains("spent"))
        #expect(!plus.contains("●"))
        let team = try #require(usage.first { $0.contains("team") })
        #expect(team.hasPrefix("▲   team● "))
        #expect(team.contains("80%"))
        #expect(team.contains("5h"))
        #expect(team.contains("↻ 4h"))
        #expect(!team.contains("spent"))
        let guest = try #require(usage.first { $0.contains("guest") })
        #expect(guest.hasPrefix("!   guest"))
        #expect(guest.hasSuffix("unavailable"))
        #expect(!guest.contains("no limit"))
        #expect(!usage.contains { $0.contains("●") && !$0.contains("team") })

        let quota = Self.render(report, view: .quota).split(separator: "\n").map(String.init)
        #expect(quota[0] == "2 at ≥80% · 0 at 50–79% · 1 unavailable")
        let quotaHeader = try #require(quota.first { $0.contains("Codex") })
        #expect(!quotaHeader.contains("%"))
        #expect(quota.contains { $0.contains("plus") && $0.contains("20%") && $0.contains("5h") })
        #expect(quota.contains { $0.contains("90%") && $0.contains("7d") && !$0.contains("plus") })
        #expect(quota.contains { $0.contains("team●") && $0.contains("80%") && $0.contains("5h") })
        #expect(quota.contains { $0.contains("10%") && $0.contains("7d") })
        let quotaGuest = try #require(quota.first { $0.contains("guest") })
        #expect(quotaGuest.hasSuffix("unavailable"))
        #expect(!quotaGuest.contains("no limit"))
    }

    @Test("codex: equal primary uses the sooner reset; a nil reset marks nobody only when none have a fraction")
    func codexAccountMark() {
        let now = CLIReportFixture.asOf
        let sooner = now.addingTimeInterval(3600)
        let later = now.addingTimeInterval(7200)
        let equal = multiCodexReport(cost: nil, accounts: [
            codexAccount("team", primary: 0.40, primaryReset: later, secondary: nil),
            codexAccount("plus", primary: 0.40, primaryReset: sooner, secondary: nil),
        ])
        let equalNames = CompactTextRenderer.usageLines(equal, now: now).map(lineName)
        #expect(equalNames.contains("  plus●"))
        #expect(equalNames.contains("  team"))
        #expect(!equalNames.contains("  team●"))

        let nilReset = multiCodexReport(cost: nil, accounts: [
            codexAccount("plus", primary: 0.50, primaryReset: nil, secondary: nil),
            codexAccount("team", primary: 0.50, primaryReset: sooner, secondary: nil),
        ])
        let nilNames = CompactTextRenderer.usageLines(nilReset, now: now).map(lineName)
        #expect(nilNames.contains("  team●"))
        #expect(!nilNames.contains("  plus●"))

        let nobody = multiCodexReport(cost: nil, accounts: [
            codexAccount("plus", primary: nil, primaryReset: nil, secondary: 0.80),
            codexAccount("team", primary: nil, primaryReset: nil, secondary: nil),
        ])
        let nobodyLines = CompactTextRenderer.usageLines(nobody, now: now)
        #expect(nobodyLines.map(lineName).allSatisfy { !$0.contains("●") })
        #expect(CompactTextRenderer.severityLine(nobodyLines) == "0 at ≥80% · 0 at 50–79% · 2 unavailable")
        let quotaLines = CompactTextRenderer.quotaLines(nobody, now: now)
        #expect(quotaLines.map(lineName).contains("  plus"))
        #expect(quotaLines.contains { line in
            if case .row(_, .bar(let fraction), let label, _, _) = line {
                return abs(fraction - 0.80) < 0.000_1 && label == "7d"
            }
            return false
        })
    }

    @Test("codex: one login stays a single compact row")
    func codexOneLoginStaysOneRow() {
        let lines = CompactTextRenderer.usageLines(CLIReportFixture.codex(), now: CLIReportFixture.asOf)
        #expect(lines.count == 1)
        #expect(lineName(lines[0]) == "Codex")
    }

    @Test("claude: header row with total, accounts indented alphabetically, ● on the active constraint")
    func claudeAccounts() {
        let lines = Self.render().split(separator: "\n").map(String.init)
        let header = lines.firstIndex { $0.hasPrefix("  Claude ") }
        let personal = lines.firstIndex { $0.hasPrefix("    personal ") }
        let work = lines.firstIndex { $0.hasPrefix("    work● ") }
        #expect(header != nil && personal != nil && work != nil)
        #expect(header! + 1 == personal! && personal! + 1 == work!)
        #expect(lines[header!].hasSuffix("$273.86 spent") && !lines[header!].contains("%"))
        #expect(lines[work!].contains("47% 7d"))
        #expect(lines[personal!].contains("17% 7d") && lines[personal!].contains("↻ unknown"))
    }

    @Test("local line: running model, stopped; placeholders hidden")
    func localLine() {
        let text = Self.render()
        #expect(text.contains("  local ○ Ollama stopped  ● llama.cpp Qwen3.5-4B"))
        #expect(!text.contains("gpu-box"))
        #expect(!text.contains("LM Studio llama.cpp"))
    }

    @Test("eighth-block bar precision", arguments: [
        (0.94, "█████████▍"), (0.69, "██████▉░░░"), (0.47, "████▊░░░░░"),
        (0.17, "█▊░░░░░░░░"), (0.0, "░░░░░░░░░░"), (1.0, "██████████"), (1.4, "██████████"),
    ])
    func eighthBar(fraction: Double, expected: String) {
        let (fill, track) = CLIFormat.eighthBar(consumed: fraction, width: 10)
        #expect(fill + track == expected)
    }

    @Test("severity edges: 80% critical, 50% warning", arguments: [
        (0.80, CompactTextRenderer.Severity.critical), (0.7996, .critical), (0.7949, .warning),
        (0.50, .warning), (0.4996, .warning), (0.4949, .normal),
    ])
    func severity(fraction: Double, expected: CompactTextRenderer.Severity) {
        #expect(CompactTextRenderer.Severity(fraction) == expected)
    }

    @Test("SI token abbreviation", arguments: [
        (0, "0"), (999, "999"), (1_500, "1.5K"), (232_400_512, "232.4M"), (1_260_000_000, "1.3B"),
        (999_949, "999.9K"), (999_950, "1.0M"), (999_950_000, "1.0B"),
    ])
    func siTokens(n: Int, expected: String) {
        #expect(CompactTextRenderer.siTokens(n) == expected)
    }

    @Test("width: COLUMNS when not a TTY, else nil")
    func terminalWidth() {
        #expect(CompactTextRenderer.terminalWidth(isTTY: false, environment: ["COLUMNS": "90"]) == 90)
        #expect(CompactTextRenderer.terminalWidth(isTTY: false, environment: ["COLUMNS": "wide"]) == nil)
        #expect(CompactTextRenderer.terminalWidth(isTTY: false, environment: [:]) == nil)
    }

    @Test("reset column: countdown, now, unknown")
    func resetColumn() {
        let now = CLIReportFixture.asOf
        #expect(CompactTextRenderer.resetColumn(now.addingTimeInterval(3 * 86400 + 8 * 3600), now: now) == "↻ 3d 8h")
        #expect(CompactTextRenderer.resetColumn(now.addingTimeInterval(-5), now: now) == "↻ now")
        #expect(CompactTextRenderer.resetColumn(nil, now: now) == "↻ unknown")
    }

    @Test("stale snapshot keeps its bar and adds a ! stale line")
    func staleRow() {
        var codex = CLIReportFixture.codex()
        codex.status = .stale(lastSuccess: CLIReportFixture.asOf, error: ProviderError(kind: .http, message: "HTTP 500"))
        let report = UsageReport(asOf: CLIReportFixture.asOf, source: .cached, providers: [codex])
        let lines = Self.render(report).split(separator: "\n").map(String.init)
        #expect(lines[2].hasPrefix("△ Codex"))
        #expect(lines[3].hasPrefix("! Codex") && lines[3].hasSuffix("stale"))
    }

    @Test("CLITheme.compact renders the same rows as the renderer")
    func themeRoutes() {
        let viaTheme = CLITheme.compact.render(CLIReportFixture.rich(), view: .quota, color: false)
        #expect(viaTheme.hasPrefix("1 at ≥80% · 2 at 50–79% · 2 unavailable\n"))
    }

    @Test("Ollama Cloud row is labelled mo, never 30d (SPEC V24)")
    func ollamaCloudMonthlyLabel() throws {
        let row = try #require(Self.render().split(separator: "\n").first { $0.contains("Ollama Cloud") })
        #expect(row.contains(" mo "))
        #expect(!row.contains("30d"))
    }

    /// V35 perf budget, run by hand: `TEST_RUNNER_AUB_BENCH=1 xcodebuild test …
    /// -only-testing:AgentsUsageBarTests/CompactTextRendererTests`. Skipped in CI.
    @Test("bench: compact render < 1 ms/iter", .enabled(if: ProcessInfo.processInfo.environment["AUB_BENCH"] == "1"))
    func benchRender() {
        let report = CLIReportFixture.rich()
        func minMicros(_ body: () -> String) -> Double {
            var best = Double.infinity
            for _ in 0..<5 {
                let iterations = 2_000
                let start = DispatchTime.now().uptimeNanoseconds
                var bytes = 0
                for _ in 0..<iterations { bytes &+= body().utf8.count }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000
                best = min(best, elapsed / Double(iterations))
                #expect(bytes > 0)
            }
            return best
        }
        let compact = minMicros { CompactTextRenderer.render(report, view: .usage, color: true, width: nil, timeZone: Self.utc) }
        let classic = minMicros { UsageTextRenderer.renderUsage(report, color: true) }
        print(String(format: "bench-render compact %.1f µs/iter, classic %.1f µs/iter", compact, classic))
        #expect(compact < 1_000)
    }

    private func assertGolden(_ actual: String, _ name: String) throws {
        let url = ClassicGoldenTests.goldenDir.appendingPathComponent(name)
        if ClassicGoldenTests.record {
            try Data(actual.utf8).write(to: url)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(actual == expected, "golden mismatch: \(name)")
    }

    @Test("rows follow provider-order; Claude accounts stay alphabetical")
    func providerOrder() {
        let text = CompactTextRenderer.render(
            CLIReportFixture.rich(), view: .usage, color: false, width: nil, timeZone: Self.utc,
            providerOrder: [.codex, .grok, .claude]
        )
        let names = text.split(separator: "\n").dropFirst(2).map { String($0.dropFirst(2).prefix(12)).trimmingCharacters(in: .whitespaces) }
        #expect(Array(names.prefix(6)) == ["Codex", "Grok", "Claude", "personal", "work●", "OpenRouter"])
    }

    @Test("text gauge rows carry no trailing spaces with colour on")
    func textGaugeNoTrailingSpaces() {
        var noLimit = CLIReportFixture.codex()
        noLimit.snapshot = UsageSnapshot(
            providerID: .codex, asOf: CLIReportFixture.asOf, tokensToday: 0,
            costTodayUSD: nil, balanceUSD: nil, quota: nil, raw: [:], quotaWindows: nil
        )
        let report = UsageReport(asOf: CLIReportFixture.asOf, source: .cached, providers: [CLIReportFixture.openrouter(), noLimit])
        for color in [false, true] {
            let rows = Self.render(report, color: color).split(separator: "\n").map(String.init)
            let row = rows.first { $0.contains("no limit") }
            #expect(row != nil)
            for line in rows {
                #expect(!line.hasSuffix(" "), "trailing space: \(line.debugDescription)")
                #expect(!line.hasSuffix(" " + CLIFormat.ansiReset), "padding inside ANSI span: \(line.debugDescription)")
            }
        }
    }
}

private func lineName(_ line: CompactTextRenderer.Line) -> String {
    switch line {
    case let .row(name, _, _, _, _): return name
    case let .problem(name, _): return name
    }
}

private func multiCodexReport(
    cost: String?,
    accounts: [UsageSnapshot.AccountUsage]
) -> ProviderReport {
    var report = CLIReportFixture.codex()
    let maxPrimary = accounts.compactMap { $0.quota?.fraction }.max()
    report.snapshot = UsageSnapshot(
        providerID: .codex,
        asOf: CLIReportFixture.asOf,
        tokensToday: 18_404,
        costTodayUSD: cost.flatMap { Decimal(string: $0) },
        balanceUSD: nil,
        quota: maxPrimary.map { Quota(used: $0, limit: 1, remaining: max(0, 1 - $0)) },
        raw: ["source": "codex-accounts"],
        quotaWindows: nil,
        accounts: accounts
    )
    return report
}

private func codexAccount(
    _ name: String,
    primary: Double?,
    primaryReset: Date?,
    secondary: Double?
) -> UsageSnapshot.AccountUsage {
    var windows: [QuotaWindow] = []
    if primary != nil || primaryReset != nil {
        windows.append(QuotaWindow(
            name: "primary",
            utilization: primary,
            resetsAt: primaryReset,
            duration: 5 * 3600
        ))
    }
    if let secondary {
        windows.append(QuotaWindow(
            name: "secondary",
            utilization: secondary,
            resetsAt: CLIReportFixture.asOf.addingTimeInterval(6 * 86400),
            duration: 7 * 86400
        ))
    }
    let quota = primary.map { Quota(used: $0, limit: 1, remaining: max(0, 1 - $0)) }
    return UsageSnapshot.AccountUsage(
        name: name,
        costTodayUSD: nil,
        quota: quota,
        quotaWindows: windows.isEmpty ? nil : windows
    )
}

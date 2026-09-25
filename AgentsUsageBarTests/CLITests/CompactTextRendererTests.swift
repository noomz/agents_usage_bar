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

    @Test("header counts each account row and every ! row")
    func headerCounts() {
        let lines = Self.render().split(separator: "\n").map(String.init)
        #expect(lines[0] == "today $273.93 spent · 233.6M tok · 05:20")
        // ≥80: OpenRouter 94. 50–79: Codex 69. !: Gemini (degraded, under its bar) + Grok.
        #expect(lines[1] == "1 at ≥80% · 1 at 50–79% · 2 unavailable")
    }

    @Test("rows follow known-provider order, never severity")
    func order() {
        let text = Self.render()
        let names = ["OpenRouter", "Claude", "Codex", "Gemini", "Grok", "local"]
        let positions = names.map { text.range(of: $0)!.lowerBound }
        #expect(positions == positions.sorted())
    }

    @Test("claude accounts alphabetical, ● on the active constraint")
    func claudeAccounts() {
        let lines = Self.render(width: 110).split(separator: "\n").map(String.init)
        let personal = lines.firstIndex { $0.contains("Claude personal") }
        let work = lines.firstIndex { $0.contains("  work●") }
        #expect(personal != nil && work != nil && personal! < work!)
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
        (0.80, CompactTextRenderer.Severity.critical), (0.7999, .warning),
        (0.50, .warning), (0.4999, .normal),
    ])
    func severity(fraction: Double, expected: CompactTextRenderer.Severity) {
        #expect(CompactTextRenderer.Severity(fraction) == expected)
    }

    @Test("SI token abbreviation", arguments: [
        (0, "0"), (999, "999"), (1_500, "1.5K"), (232_400_512, "232.4M"), (1_260_000_000, "1.3B"),
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
        #expect(viaTheme.hasPrefix("1 at ≥80% · 1 at 50–79% · 2 unavailable\n"))
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
}

import Foundation
import Testing
@testable import AgentsUsageBar

/// Full-output golden tests guarding `classic` (`UsageTextRenderer`) and
/// `--json` byte-identity (SPEC V5, V6). Goldens were captured on `main`
/// @ 8f18d6c before any CLI theme refactor.
///
/// Re-record (only when an output change is intended):
/// `TEST_RUNNER_AUB_RECORD_GOLDEN=1 xcodebuild test … -only-testing:AgentsUsageBarTests/ClassicGoldenTests`
@Suite("Classic golden output")
struct ClassicGoldenTests {

    static let goldenDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Golden")

    static let record = ProcessInfo.processInfo.environment["AUB_RECORD_GOLDEN"] == "1"

    @Test("classic renders for the pinned test locale")
    func pinnedLocale() {
        // Classic formats numbers and USD with Locale.current; the test plan pins en/US.
        #expect(Locale.current.identifier == "en_US")
    }

    @Test("classic usage, no colour")
    func usagePlain() throws {
        try assertGolden(UsageTextRenderer.renderUsage(CLIReportFixture.rich(), color: false), "classic-usage.txt")
    }

    @Test("classic usage, colour")
    func usageColor() throws {
        try assertGolden(UsageTextRenderer.renderUsage(CLIReportFixture.rich(), color: true), "classic-usage-color.txt")
    }

    @Test("classic quota, no colour")
    func quotaPlain() throws {
        try assertGolden(UsageTextRenderer.renderQuota(CLIReportFixture.rich(), color: false), "classic-quota.txt")
    }

    @Test("classic quota, colour")
    func quotaColor() throws {
        try assertGolden(UsageTextRenderer.renderQuota(CLIReportFixture.rich(), color: true), "classic-quota-color.txt")
    }

    @Test("json usage")
    func jsonUsage() throws {
        try assertGolden(UsageJSONRenderer.renderUsage(CLIReportFixture.rich()), "json-usage.json")
    }

    @Test("json quota")
    func jsonQuota() throws {
        try assertGolden(UsageJSONRenderer.renderQuota(CLIReportFixture.rich()), "json-quota.json")
    }

    private func assertGolden(_ actual: String, _ name: String) throws {
        let url = Self.goldenDir.appendingPathComponent(name)
        if Self.record {
            try FileManager.default.createDirectory(at: Self.goldenDir, withIntermediateDirectories: true)
            try Data(actual.utf8).write(to: url)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(actual == expected, "golden mismatch: \(name)")
    }
}

import Foundation
import XCTest
@testable import AgentsUsageBar

final class AntigravityProviderTests: XCTestCase {
    func testReportsGroupedQuotaWithoutTokenOrCostTotals() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/usage.json")
        let cli = try fakeCLI("""
            [ "$PWD" = / ] && [ "$*" = '--print /usage --output-format json --print-timeout 8s' ] || exit 1
            exec /bin/cat "$HOME/usage.json"
            """)
        try FileManager.default.copyItem(at: fixture, to: cli.home.appendingPathComponent("usage.json"))
        let result = try await AntigravityProvider(cli: cli).fetch(now: .now)
        let windows = try XCTUnwrap(result.quotaWindows)
        XCTAssertEqual(windows.map(\.name), ["Gemini Models 7d", "Gemini Models 5h", "Claude and GPT models 7d", "Claude and GPT models 5h"])
        XCTAssertEqual(windows.map(\.utilization), [0.25, 0, 1, 0.5])
        XCTAssertEqual(windows.map(\.duration), [604_800, 18_000, 604_800, 18_000])
        XCTAssertEqual(windows[3].resetsAt?.timeIntervalSince1970 ?? 0, 1_795_183_219.123, accuracy: 0.001)
        XCTAssertEqual(result.quota?.used, 1)
        XCTAssertEqual(result.accountInfo?.billingModel, .subscription)
        XCTAssertNil(result.tokensToday)
        XCTAssertNil(result.costTodayUSD)
    }

    func testDoesNotLaunchCLIWithoutLogin() async throws {
        let cli = try fakeCLI("exit 1", signedIn: false)
        let provider = AntigravityProvider(cli: cli)
        let result = try await provider.fetch(now: .now)
        let status = await provider.status()
        XCTAssertEqual(status, .unauthenticated)
        XCTAssertNil(result.quota)
    }

    func testInvalidQuotaIsAnErrorRatherThanUnlimited() async throws {
        let cli = try fakeCLI(#"printf '%s' '{"status":"SUCCESS","response":"No usage available"}'"#)
        do {
            _ = try await AntigravityProvider(cli: cli).fetch(now: .now)
            XCTFail("Expected invalid quota to fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, .decode)
        }
    }

    func testHungCLITimesOut() async throws {
        var cli = try fakeCLI("exec /bin/sleep 60")
        cli.timeout = 0.2
        do {
            _ = try await AntigravityProvider(cli: cli).fetch(now: .now)
            XCTFail("Expected the quota poll to time out")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, .network)
        }
    }

    private func fakeCLI(_ script: String, signedIn: Bool = true) throws -> AntigravityCLI {
        let fs = FileManager.default
        let home = fs.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fs.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        if signedIn {
            let login = home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
            try fs.createDirectory(at: login.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: login)
        }
        let executable = home.appendingPathComponent("agy")
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try fs.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return AntigravityCLI(executable: executable, home: home)
    }
}

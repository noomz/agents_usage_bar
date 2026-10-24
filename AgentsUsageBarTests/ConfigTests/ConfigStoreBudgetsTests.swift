import Foundation
import Testing
@testable import AgentsUsageBar

// SPEC V39 — `[budgets]` in config.toml is the base; values edited in Settings win.
// Amounts are round synthetic numbers (C3).

@Suite("ConfigStoreBudgetsTests", .serialized)
@MainActor
struct ConfigStoreBudgetsTests {

    private func store(toml: String?) throws -> ConfigStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ConfigStoreBudgetsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "config.toml")
        if let toml { try Data(toml.utf8).write(to: path) }
        return ConfigStore(env: DictionaryEnvReader([:]), tomlPath: path)
    }

    private func preferences() -> UserPreferencesStore {
        UserPreferencesStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
    }

    @Test("no [budgets] section means no budget")
    func unsetIsNoBudget() throws {
        #expect(try store(toml: nil).load().budgets == .none)
    }

    @Test("total and per-provider caps parse from ints and doubles")
    func parsesCaps() throws {
        let toml = "[budgets]\ntotal_usd = 50\nclaude_usd = 20.5\ncodex_usd = 10\nopenrouter_usd = 5\n"
        let caps = try store(toml: toml).load().budgets.caps
        #expect(caps == [
            .total: Money(50),
            .provider(.claude): Money(Decimal(string: "20.5")!),
            .provider(.codex): Money(10),
            .provider(.openrouter): Money(5),
        ])
    }

    @Test("zero, negative, non-number, and non-cost-reporting keys are no budget")
    func ignoresInvalid() throws {
        let toml = "[budgets]\ntotal_usd = 0\nclaude_usd = -5\ncodex_usd = \"ten\"\ngemini_usd = 10\n"
        #expect(try store(toml: toml).load().budgets == .none)
    }

    @Test("a Settings value wins over config, zero turns it off, nil falls back")
    func settingsWin() async throws {
        let config = try store(toml: "[budgets]\ntotal_usd = 50\nclaude_usd = 20\n")
        let prefs = preferences()
        prefs.setBudget(.total, usd: 80)
        prefs.setBudget(.provider(.claude), usd: 0)
        prefs.setBudget(.provider(.codex), usd: 15)
        try await Task.sleep(for: .milliseconds(50))
        #expect(config.load(preferences: prefs).budgets.caps == [
            .total: Money(80),
            .provider(.codex): Money(15),
        ])

        prefs.setBudget(.total, usd: nil)
        prefs.setBudget(.provider(.claude), usd: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(prefs.budgetOverrides == [.provider(.codex): 15])
        #expect(config.load(preferences: prefs).budgets.caps == [
            .total: Money(50),
            .provider(.claude): Money(20),
            .provider(.codex): Money(15),
        ])
    }
}

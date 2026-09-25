import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("CLITheme selection")
struct CLIThemeSelectionTests {

    private func resolve(
        flag: CLITheme? = nil,
        env: String? = nil,
        setting: CLITheme? = nil
    ) -> Result<CLITheme.Selection, AUBParseError> {
        CLITheme.resolve(flag: flag, env: { env }, setting: { setting })
    }

    @Test("precedence flag > env > setting > compact")
    func precedence() {
        #expect(try! resolve(flag: .classic, env: "compact", setting: .compact).get()
                == .init(theme: .classic, source: .flag))
        #expect(try! resolve(env: "classic", setting: .compact).get()
                == .init(theme: .classic, source: .env))
        #expect(try! resolve(setting: .classic).get() == .init(theme: .classic, source: .setting))
        #expect(try! resolve().get() == .init(theme: .compact, source: .default))
    }

    @Test("empty AUB_THEME counts as unset")
    func emptyEnv() {
        #expect(try! resolve(env: "", setting: .classic).get() == .init(theme: .classic, source: .setting))
    }

    @Test("env is case-insensitive")
    func envCase() {
        #expect(try! resolve(env: "CLASSIC").get().theme == .classic)
    }

    @Test("invalid AUB_THEME errors with prefix")
    func invalidEnv() {
        let result = resolve(env: "fancy", setting: .classic)
        #expect(result == .failure(.unknownThemeEnv("fancy")))
        #expect(AUBParseError.unknownThemeEnv("fancy").description
                == "AUB_THEME: unknown CLI theme 'fancy'; expected compact|classic")
    }

    @Test("lower sources are not read when a higher one wins")
    func lazy() {
        var envReads = 0
        var settingReads = 0
        _ = CLITheme.resolve(
            flag: .classic,
            env: { envReads += 1; return "compact" },
            setting: { settingReads += 1; return .compact }
        )
        #expect(envReads == 0 && settingReads == 0)
        _ = CLITheme.resolve(
            flag: nil,
            env: { envReads += 1; return "classic" },
            setting: { settingReads += 1; return .compact }
        )
        #expect(envReads == 1 && settingReads == 0)
    }

    @Test("themes text listing")
    func listText() {
        let text = CLITheme.renderList(active: .init(theme: .classic, source: .env))
        #expect(text == [
            "  compact  One row per provider with severity glyphs (default)",
            "● classic  Original multi-line layout",
            "active: classic (from AUB_THEME)",
            "",
        ].joined(separator: "\n"))
        let byDefault = CLITheme.renderList(active: .init(theme: .compact, source: .default))
        #expect(byDefault.hasPrefix("● compact  "))
        #expect(byDefault.hasSuffix("active: compact (from default)\n"))
    }

    @Test("themes JSON listing")
    func listJSON() throws {
        let json = try CLITheme.renderListJSON(active: .init(theme: .classic, source: .env))
        #expect(json == #"{"active":"classic","source":"env","themes":[{"default":true,"description":"One row per provider with severity glyphs","name":"compact"},{"default":false,"description":"Original multi-line layout","name":"classic"}]}"# + "\n")
    }

    @Test("help text documents --theme and env")
    func help() {
        #expect(AUBCommand.helpText.contains("  --theme NAME    CLI theme: compact (default) | classic\n"))
        #expect(AUBCommand.helpText.contains("AUB_THEME"))
        #expect(AUBCommand.helpText.contains("NO_COLOR"))
        #expect(AUBCommand.helpText.contains("aub themes"))
        #expect(AUBCommand.helpText.contains("cli-theme"))
    }
}

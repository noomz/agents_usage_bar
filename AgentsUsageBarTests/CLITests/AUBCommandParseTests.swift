import Testing
@testable import AgentsUsageBar

@Suite("AUBCommand.parse")
struct AUBCommandParseTests {

    @Test("empty args default to usage of enabled providers")
    func emptyIsUsage() {
        let cmd = try! AUBCommand.parse([]).get()
        #expect(cmd == .usage(AUBCommand.UsageOptions()))
    }

    @Test("usage --json --cached --no-color")
    func usageFlags() {
        let cmd = try! AUBCommand.parse(["usage", "--json", "--cached", "--no-color"]).get()
        #expect(cmd == .usage(.init(filter: .enabled, json: true, noColor: true, cached: true)))
    }

    @Test("positional provider")
    func positionalProvider() {
        let cmd = try! AUBCommand.parse(["usage", "claude"]).get()
        #expect(cmd == .usage(.init(filter: .one(.claude))))
    }

    @Test("bare provider id is usage")
    func bareProvider() {
        let cmd = try! AUBCommand.parse(["grok"]).get()
        #expect(cmd == .usage(.init(filter: .one(.grok))))
    }

    @Test("--provider all")
    func providerAll() {
        let cmd = try! AUBCommand.parse(["--provider", "all"]).get()
        #expect(cmd == .usage(.init(filter: .all)))
    }

    @Test("quota is limits alias")
    func quotaAndLimits() {
        #expect(try! AUBCommand.parse(["quota"]).get() == .quota(.init()))
        #expect(try! AUBCommand.parse(["limits", "codex"]).get() == .quota(.init(filter: .one(.codex))))
    }

    @Test("unknown provider")
    func unknownProvider() {
        let result = AUBCommand.parse(["usage", "nope"])
        #expect(result == .failure(.unknownProvider("nope")))
    }

    @Test("unknown command")
    func unknownCommand() {
        let result = AUBCommand.parse(["frobnicate"])
        #expect(result == .failure(.unknownCommand("frobnicate")))
    }

    @Test("settings list/get/set")
    func settings() {
        #expect(try! AUBCommand.parse(["settings"]).get() == .settings(.list, json: false))
        #expect(try! AUBCommand.parse(["settings", "get", "theme"]).get() == .settings(.get("theme"), json: false))
        #expect(
            try! AUBCommand.parse(["settings", "set", "theme", "dark"]).get()
            == .settings(.set(key: "theme", value: "dark"), json: false)
        )
        #expect(try! AUBCommand.parse(["settings", "--json"]).get() == .settings(.list, json: true))
    }

    @Test("settings get missing key")
    func settingsMissingKey() {
        #expect(AUBCommand.parse(["settings", "get"]) == .failure(.missingSettingsKey))
    }

    @Test("install --prefix")
    func installPrefix() {
        #expect(try! AUBCommand.parse(["install", "--prefix", "/tmp/bin"]).get() == .install(prefix: "/tmp/bin"))
        #expect(try! AUBCommand.parse(["uninstall"]).get() == .uninstall)
    }

    @Test("help and version flags")
    func helpVersion() {
        #expect(try! AUBCommand.parse(["--help"]).get() == .help)
        #expect(try! AUBCommand.parse(["-h"]).get() == .help)
        #expect(try! AUBCommand.parse(["--version"]).get() == .version)
        #expect(try! AUBCommand.parse(["version"]).get() == .version)
    }

    @Test("strips --cli")
    func stripsCLI() {
        let cmd = try! AUBCommand.parse(["--cli", "usage", "--json"]).get()
        #expect(cmd == .usage(.init(json: true)))
    }

    @Test("isSubcommand ignores LaunchServices psn")
    func ignoresPSN() {
        #expect(!AUBCommand.isSubcommand("-psn_0_12345"))
        #expect(AUBCommand.isSubcommand("usage"))
        #expect(AUBCommand.isSubcommand("claude"))
        #expect(AUBCommand.isSubcommand("--json"))
    }
}

import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - Test environment helper

/// A throwaway temp environment: an isolated `settings.json` path + feed dir, both under
/// a unique temp root that is torn down after each test. Uses the real `FileManager`
/// against the temp tree (no home-dir access).
private struct HookTestEnv {
    let root: URL
    let settingsPath: URL
    let feedDir: URL
    let installer: ClaudeHookInstaller

    init() throws {
        let fm = FileManager.default
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-installer-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        settingsPath = root.appendingPathComponent(".claude/settings.json", isDirectory: false)
        feedDir = root.appendingPathComponent("claude-hook", isDirectory: true)
        installer = ClaudeHookInstaller(
            fileManager: fm,
            settingsPath: settingsPath,
            feedDir: feedDir
        )
    }

    var scriptURL: URL { feedDir.appendingPathComponent("aub-statusline.sh") }
    var originalStatuslineURL: URL { feedDir.appendingPathComponent("original-statusline.json") }

    func writeSettings(_ dict: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try data.write(to: settingsPath)
    }

    func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsPath)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func readScript() throws -> String {
        try String(contentsOf: scriptURL, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - ClaudeHookInstallerTests

@Suite("ClaudeHookInstallerTests", .serialized)
struct ClaudeHookInstallerTests {

    // MARK: Fresh install (no prior statusline)

    @Test func installFresh_wiresStatusLine_noBackup_preservesKeys() throws {
        let env = try HookTestEnv()
        defer { env.cleanup() }

        try env.writeSettings([
            "model": "opusplan",
            "env": ["FOO": "bar"] as [String: Any],
            "permissions": ["allow": ["Bash"]] as [String: Any]
        ])

        try env.installer.install()

        // statusLine is now ours.
        #expect(env.installer.status() == .installed)
        let settings = try env.readSettings()
        let statusLine = try #require(settings["statusLine"] as? [String: Any])
        #expect(statusLine["type"] as? String == "command")
        let command = try #require(statusLine["command"] as? String)
        #expect(command.contains("aub-statusline.sh"))

        // Unknown keys survived untouched.
        #expect(settings["model"] as? String == "opusplan")
        #expect((settings["env"] as? [String: Any])?["FOO"] as? String == "bar")
        #expect(((settings["permissions"] as? [String: Any])?["allow"] as? [String]) == ["Bash"])

        // No original statusline existed → no backup file.
        #expect(!FileManager.default.fileExists(atPath: env.originalStatuslineURL.path))

        // Script written, correct shape, no chain.
        let script = try env.readScript()
        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(script.contains(env.feedDir.appendingPathComponent("sessions").path))
        #expect(!script.contains("chained original statusline"))
    }

    // MARK: Missing settings.json is created

    @Test func installFresh_missingSettings_createsFile() throws {
        let env = try HookTestEnv()
        defer { env.cleanup() }

        #expect(!FileManager.default.fileExists(atPath: env.settingsPath.path))

        try env.installer.install()

        #expect(FileManager.default.fileExists(atPath: env.settingsPath.path))
        #expect(env.installer.status() == .installed)
        let settings = try env.readSettings()
        #expect((settings["statusLine"] as? [String: Any])?["command"] != nil)
    }

    // MARK: Install over a foreign statusline whose command contains quotes

    @Test func installOverForeign_withQuotedCommand_backsUpAndChainsVerbatim() throws {
        let env = try HookTestEnv()
        defer { env.cleanup() }

        // A command bristling with single AND double quotes and a `$` — must survive verbatim.
        let foreignCommand = #"sh -c 'printf "hud: %s\n" "$USER"'"#
        try env.writeSettings([
            "statusLine": ["type": "command", "command": foreignCommand] as [String: Any],
            "model": "sonnet"
        ])

        #expect(env.installer.status() == .foreignStatusline)

        try env.installer.install()

        // Backup written with the original command intact.
        #expect(FileManager.default.fileExists(atPath: env.originalStatuslineURL.path))
        let backupData = try Data(contentsOf: env.originalStatuslineURL)
        let backup = try #require(
            try JSONSerialization.jsonObject(with: backupData) as? [String: Any]
        )
        #expect(backup["command"] as? String == foreignCommand)

        // The script chains the original command embedded verbatim on its own line.
        let script = try env.readScript()
        #expect(script.contains("chained original statusline"))
        #expect(script.contains(#"printf '%s' "$input" | "# + foreignCommand))

        // settings.json now points at us; unknown key preserved.
        #expect(env.installer.status() == .installed)
        let settings = try env.readSettings()
        #expect((settings["model"] as? String) == "sonnet")
    }

    // MARK: Uninstall restores the foreign statusline

    @Test func uninstall_restoresForeignStatusline_removesScriptAndBackup() throws {
        let env = try HookTestEnv()
        defer { env.cleanup() }

        let foreignCommand = #"my-hud --json '{"k":"v"}'"#
        try env.writeSettings([
            "statusLine": ["type": "command", "command": foreignCommand] as [String: Any]
        ])
        try env.installer.install()
        #expect(env.installer.status() == .installed)

        try env.installer.uninstall()

        // statusLine restored to the exact foreign command.
        let settings = try env.readSettings()
        let statusLine = try #require(settings["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == foreignCommand)
        #expect(env.installer.status() == .foreignStatusline)

        // Backup + script gone.
        #expect(!FileManager.default.fileExists(atPath: env.originalStatuslineURL.path))
        #expect(!FileManager.default.fileExists(atPath: env.scriptURL.path))
    }

    // MARK: Uninstall a fresh install removes the statusLine key entirely

    @Test func uninstall_afterFreshInstall_removesStatusLineKey() throws {
        let env = try HookTestEnv()
        defer { env.cleanup() }

        try env.writeSettings(["model": "opus"])
        try env.installer.install()
        #expect(env.installer.status() == .installed)

        try env.installer.uninstall()

        let settings = try env.readSettings()
        #expect(settings["statusLine"] == nil)
        #expect(settings["model"] as? String == "opus")
        #expect(env.installer.status() == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: env.scriptURL.path))
    }

    // MARK: Unknown keys are preserved byte-for-value across install + uninstall

    @Test func unknownKeys_preservedAcrossInstallUninstall() throws {
        let env = try HookTestEnv()
        defer { env.cleanup() }

        let original: [String: Any] = [
            "model": "opusplan",
            "cleanupPeriodDays": 30,
            "includeCoAuthoredBy": false,
            "env": ["A": "1", "B": "2"] as [String: Any],
            "permissions": ["allow": ["Bash", "Read"], "deny": []] as [String: Any],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "echo hi"]]]]] as [String: Any]
        ]
        try env.writeSettings(original)

        try env.installer.install()
        try env.installer.uninstall()

        // After a fresh install + uninstall, everything except the (removed) statusLine
        // key must equal the original, value-for-value.
        var expected = original
        // (no statusLine was present originally)
        let result = try env.readSettings()
        #expect(result["statusLine"] == nil)

        expected.removeValue(forKey: "statusLine")
        #expect(NSDictionary(dictionary: result).isEqual(to: expected))
    }

    // MARK: Symlinked settings.json survives install (dotfiles managers)

    @Test func install_preservesSymlinkAndPermissions() throws {
        let env = try HookTestEnv()
        defer { env.cleanup() }

        let fm = FileManager.default
        // Real file lives elsewhere (dotfiles repo); ~/.claude/settings.json is a symlink.
        let dotfilesTarget = env.root.appendingPathComponent("dotfiles/settings.json", isDirectory: false)
        try fm.createDirectory(at: dotfilesTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["model": "opusplan"], options: [])
        try data.write(to: dotfilesTarget)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dotfilesTarget.path)
        try fm.createDirectory(at: env.settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: env.settingsPath, withDestinationURL: dotfilesTarget)

        try env.installer.install()

        // The symlink is still a symlink; the write landed in the resolved target.
        let linkDestination = try fm.destinationOfSymbolicLink(atPath: env.settingsPath.path)
        #expect(URL(fileURLWithPath: linkDestination).standardizedFileURL.path
                == dotfilesTarget.standardizedFileURL.path)
        let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: dotfilesTarget)) as? [String: Any]
        #expect((updated?["statusLine"] as? [String: Any]) != nil)
        // Original 0o600 mode is preserved on the target.
        let mode = try #require(fm.attributesOfItem(atPath: dotfilesTarget.path)[.posixPermissions] as? Int)
        #expect(mode == 0o600)
    }

    // MARK: Backup pruning keeps the 3 newest aub-backup files

    @Test func install_prunesOldBackups_keepingThreeNewest() throws {
        let env = try HookTestEnv()
        defer { env.cleanup() }

        try env.writeSettings(["model": "opusplan"])
        let dir = env.settingsPath.deletingLastPathComponent()
        // Seed 4 fake old backups with ascending epochs.
        for epoch in [1_000, 2_000, 3_000, 4_000] {
            let url = URL(fileURLWithPath: env.settingsPath.path + ".aub-backup-\(epoch)")
            try Data("{}".utf8).write(to: url)
        }

        try env.installer.install()  // writes a 5th (current-epoch) backup, then prunes to 3

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("settings.json.aub-backup-") }
            .compactMap { Int($0.dropFirst("settings.json.aub-backup-".count)) }
            .sorted()
        #expect(backups.count == 3)
        // The three newest survive: 3000, 4000, and the fresh current-epoch one.
        #expect(backups.contains(3_000))
        #expect(backups.contains(4_000))
        #expect(backups.last! > 4_000)
    }

    // MARK: Per-account targets (DESIGN-hook-multi-account)

    @Test func discoverTargets_defaultPlusInstances_sorted() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        // Two instances: "work" has a settings.json, "personal" does not (still a target —
        // install() creates missing files). A stray file must not become a target.
        try fm.createDirectory(at: home.appendingPathComponent(".ccs/instances/work"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".ccs/instances/personal"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appendingPathComponent(".ccs/instances/work/settings.json"))
        try Data().write(to: home.appendingPathComponent(".ccs/instances/strayfile"))

        let targets = ClaudeHookInstaller.discoverTargets(fileManager: fm, home: home.path)

        #expect(targets.map(\.slug) == ["default", "personal", "work"])
        #expect(targets[0].settingsPath.path == home.path + "/.claude/settings.json")
        #expect(targets[1].settingsPath.path == home.path + "/.ccs/instances/personal/settings.json")
    }

    /// ccs symlinks every instance's settings.json to ~/.ccs/shared/settings.json —
    /// targets resolving to the same file fold into ONE row (the runtime-routed tee
    /// attributes accounts via $CLAUDE_CONFIG_DIR, so one install covers all of them).
    @Test func discoverTargets_symlinkedSharedSettings_dedupes() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let shared = home.appendingPathComponent(".ccs/shared/settings.json")
        try fm.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: shared)
        for slug in ["personal", "work"] {
            let dir = home.appendingPathComponent(".ccs/instances/\(slug)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: dir.appendingPathComponent("settings.json"),
                withDestinationURL: shared
            )
        }

        let targets = ClaudeHookInstaller.discoverTargets(fileManager: fm, home: home.path)

        // default (own file) + one folded row for the two symlinked instances.
        #expect(targets.map(\.slug) == ["default", "personal"])
        #expect(targets[1].displayName == "personal, work")
    }

    @Test func discoverTargets_noInstancesDir_defaultOnly() {
        let home = NSTemporaryDirectory() + "hook-home-\(UUID().uuidString)"
        let targets = ClaudeHookInstaller.discoverTargets(home: home)
        #expect(targets.map(\.slug) == ["default"])
    }

    @Test func slugAwareInstall_sideBySide_independentTargets() throws {
        let env = try HookTestEnv()
        defer { env.cleanup() }

        // Instance settings.json lives in its own dir, shares the feed dir.
        let instanceSettings = env.root.appendingPathComponent(
            ".ccs/instances/personal/settings.json", isDirectory: false)
        let instanceInstaller = ClaudeHookInstaller(
            fileManager: .default,
            settingsPath: instanceSettings,
            feedDir: env.feedDir,
            slug: "personal"
        )

        try env.writeSettings(["model": "opusplan"])
        try env.installer.install()          // default slug
        try instanceInstaller.install()      // "personal" slug

        // Two distinct script files; BOTH route the account at runtime from
        // $CLAUDE_CONFIG_DIR into <sessions root>/<account> (shared-settings layouts
        // make install-time path embedding unable to tell accounts apart).
        let defaultScript = try env.readScript()
        let personalScriptURL = env.feedDir.appendingPathComponent("aub-statusline-personal.sh")
        let personalScript = try String(contentsOf: personalScriptURL, encoding: .utf8)
        for script in [defaultScript, personalScript] {
            #expect(script.contains("FEED_ROOT=\"\(env.feedDir.appendingPathComponent("sessions").path)\""))
            #expect(script.contains("CLAUDE_CONFIG_DIR"))
            #expect(script.contains("acct=\"${acct:-default}\""))
            #expect(script.contains("FEED_DIR=\"$FEED_ROOT/$acct\""))
        }

        // Both settings wired; statuses independent.
        #expect(env.installer.status() == .installed)
        #expect(instanceInstaller.status() == .installed)

        // Uninstalling the instance leaves the default untouched.
        try instanceInstaller.uninstall()
        #expect(instanceInstaller.status() == .notInstalled)
        #expect(env.installer.status() == .installed)
        #expect(FileManager.default.fileExists(atPath: env.scriptURL.path))
        #expect(!FileManager.default.fileExists(atPath: personalScriptURL.path))
    }
}

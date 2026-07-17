import Foundation
import os

/// Installs / removes the "hook" (statusline-tee) integration into the user's
/// Claude Code configuration (`~/.claude/settings.json`).
///
/// Claude Code pushes REAL per-session usage (`cost.total_cost_usd`) and rate-limit
/// windows (`rate_limits.five_hour|seven_day`) to whatever program is configured as its
/// `statusLine` command, on stdin, as JSON. This installer wires a small POSIX-sh tee
/// script (`aub-statusline.sh`) into that slot. The script captures each statusline
/// payload into `<feedDir>/sessions/<session_id>.json` (consumed by `ClaudeHookProvider`)
/// and then chains through to the user's *original* statusline command, so anything the
/// user already ran (e.g. `omc-hud`) keeps working transparently.
///
/// Invariants (design §5, §4):
/// - `~/.claude/settings.json` is written ONLY on explicit `install()` / `uninstall()`.
/// - Unknown `settings.json` keys are preserved — we round-trip through a
///   `JSONSerialization` dictionary and mutate only the `statusLine` key, never a
///   `Codable` struct that would silently drop keys it doesn't model.
/// - A timestamped backup (`settings.json.aub-backup-<epoch>`) is written beside the
///   original before every mutating write.
/// - The user's prior `statusLine` (if any, and not already ours) is saved verbatim to
///   `<feedDir>/original-statusline.json`; its absence means the user had none.
/// - The original command is embedded into the generated script on its own line,
///   verbatim, so a command containing quotes survives intact (it is NOT wrapped in a
///   shell-quoted variable).
/// - All writes are atomic (write-to-temp + rename, via `Data.WritingOptions.atomic`).
///
/// The generated script is produced by a string template in Swift at install time — it is
/// NOT shipped as a bundle resource, so there is nothing extra to copy or code-sign.
public struct ClaudeHookInstaller: Sendable {

    // MARK: - Status

    /// Current state of the Claude `statusLine` slot relative to our integration.
    public enum Status: String, Sendable, Equatable {
        /// Our tee script is wired into `statusLine`.
        case installed
        /// No `statusLine` configured at all.
        case notInstalled
        /// A `statusLine` exists but it is not ours — `install()` will chain through it.
        case foreignStatusline
    }

    // MARK: - Constants

    /// Substring that uniquely identifies our tee script inside a `statusLine.command`.
    private static let scriptFileName = "aub-statusline.sh"

    // MARK: - Stored properties

    // nonisolated(unsafe): FileManager is not Sendable in Swift 6; `.default` is a
    // thread-safe singleton per Apple docs, and tests inject `.default` too. We only call
    // read/write file APIs, all self-synchronising.
    nonisolated(unsafe) private let fileManager: FileManager
    private let settingsPath: URL
    private let feedDir: URL
    private let logger = AppLogger.logger(category: "claude")

    // MARK: - Derived paths

    private var scriptURL: URL {
        feedDir.appendingPathComponent(Self.scriptFileName, isDirectory: false)
    }

    private var sessionsDir: URL {
        feedDir.appendingPathComponent("sessions", isDirectory: true)
    }

    private var originalStatuslineURL: URL {
        feedDir.appendingPathComponent("original-statusline.json", isDirectory: false)
    }

    // MARK: - Init

    /// Designated initialiser — all filesystem seams injected for testability.
    ///
    /// - Parameters:
    ///   - fileManager: Injected `FileManager` (tests pass `.default` against temp dirs).
    ///   - settingsPath: Path to Claude Code's `settings.json`. Production default is
    ///     `~/.claude/settings.json`.
    ///   - feedDir: Directory that holds the tee script, the session feed, and the
    ///     original-statusline backup. Production default is
    ///     `~/Library/Application Support/AgentsUsageBar/claude-hook`.
    public init(
        fileManager: FileManager = .default,
        settingsPath: URL = ClaudeHookInstaller.defaultSettingsPath(),
        feedDir: URL = ClaudeHookInstaller.defaultFeedDir()
    ) {
        self.fileManager = fileManager
        self.settingsPath = settingsPath
        self.feedDir = feedDir
    }

    // MARK: - Default production paths

    /// Production `settings.json` path: `~/.claude/settings.json`.
    public static func defaultSettingsPath() -> URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json", isDirectory: false)
    }

    /// Production feed directory: `~/Library/Application Support/AgentsUsageBar/claude-hook`.
    public static func defaultFeedDir() -> URL {
        URL(
            fileURLWithPath: NSHomeDirectory()
                + "/Library/Application Support/AgentsUsageBar/claude-hook",
            isDirectory: true
        )
    }

    // MARK: - Status

    /// Reports whether our tee is installed, absent, or a foreign statusline is present.
    ///
    /// Non-throwing: an unreadable / malformed `settings.json` is reported as
    /// `.notInstalled` (the safest assumption — `install()` will create/overwrite it).
    public func status() -> Status {
        let settings = (try? readSettings()) ?? [:]
        guard let statusLine = settings["statusLine"] else { return .notInstalled }
        if let dict = statusLine as? [String: Any],
           let command = dict["command"] as? String,
           command.contains(Self.scriptFileName) {
            return .installed
        }
        return .foreignStatusline
    }

    // MARK: - Install

    /// Installs the statusline tee into `settings.json`, chaining any existing statusline.
    ///
    /// Steps:
    /// 1. Read current `settings.json` (empty dict if the file is missing).
    /// 2. Determine the "original" statusline to preserve & chain: the existing
    ///    `statusLine` if it is not already ours, otherwise the prior backup (re-install).
    /// 3. Persist that original verbatim to `original-statusline.json` (or clear a stale
    ///    backup when there is no original).
    /// 4. Write the tee script with the original command embedded verbatim on its own line.
    /// 5. Back up `settings.json` to `settings.json.aub-backup-<epoch>` (if it exists).
    /// 6. Set `statusLine = {type:"command", command:"sh \"<script>\""}` and write atomically.
    public func install() throws {
        var settings = try readSettings()

        let existing = settings["statusLine"] as? [String: Any]
        let existingIsOurs = Self.commandIsOurs(existing?["command"] as? String)

        // 2. The statusline we should preserve and chain through.
        let originalStatusLine: [String: Any]?
        if let existing, !existingIsOurs {
            originalStatusLine = existing
        } else if existingIsOurs {
            // Re-install: reuse whatever we backed up the first time (may be nil).
            originalStatusLine = try? readOriginalBackup()
        } else {
            originalStatusLine = nil
        }

        // Ensure directories exist before writing anything.
        try fileManager.createDirectory(at: feedDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 3. Persist / clear the original-statusline backup.
        if let originalStatusLine {
            let data = try JSONSerialization.data(
                withJSONObject: originalStatusLine,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: originalStatuslineURL, options: .atomic)
        } else if fileManager.fileExists(atPath: originalStatuslineURL.path) {
            try? fileManager.removeItem(at: originalStatuslineURL)
        }

        // 4. Write the tee script (original command embedded verbatim on its own line).
        let originalCommand = originalStatusLine?["command"] as? String
        let script = Self.scriptContents(
            sessionsPath: sessionsDir.path,
            originalCommand: originalCommand
        )
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // 5. Timestamped backup of settings.json (only if it already exists), then prune
        //    old backups keeping the 3 newest so repeated installs don't litter ~/.claude.
        if fileManager.fileExists(atPath: settingsPath.path) {
            let epoch = Int(Date().timeIntervalSince1970)
            let backupURL = URL(fileURLWithPath: settingsPath.path + ".aub-backup-\(epoch)")
            try? fileManager.copyItem(at: settingsPath, to: backupURL)
            pruneOldBackups(keeping: 3)
        }

        // 6. Point statusLine at our script and write atomically.
        // Quote the path — the production feed dir lives under "Application Support"
        // (contains a space), so an unquoted `sh <path>` would break when Claude runs it.
        settings["statusLine"] = [
            "type": "command",
            "command": "sh \"\(scriptURL.path)\""
        ] as [String: Any]
        try writeSettings(settings)

        logger.notice("Claude statusline hook installed (chained original: \(originalCommand != nil, privacy: .public))")
    }

    // MARK: - Uninstall

    /// Removes the tee integration and restores the user's prior statusline.
    ///
    /// - If `original-statusline.json` exists, its contents are restored into
    ///   `statusLine` and the backup file is deleted.
    /// - Otherwise, if the current `statusLine` is ours, the key is removed entirely.
    /// - A foreign `statusLine` we never installed over is left untouched.
    /// - The tee script is deleted. The `sessions/` feed data is intentionally left in place.
    public func uninstall() throws {
        var settings = try readSettings()
        let backup = try? readOriginalBackup()

        let current = settings["statusLine"] as? [String: Any]
        let currentIsOurs = Self.commandIsOurs(current?["command"] as? String)

        if let backup {
            settings["statusLine"] = backup
        } else if currentIsOurs {
            settings.removeValue(forKey: "statusLine")
        }

        // Only rewrite settings.json if it exists — nothing to uninstall from otherwise.
        if fileManager.fileExists(atPath: settingsPath.path) {
            try writeSettings(settings)
        }

        if fileManager.fileExists(atPath: originalStatuslineURL.path) {
            try? fileManager.removeItem(at: originalStatuslineURL)
        }
        if fileManager.fileExists(atPath: scriptURL.path) {
            try? fileManager.removeItem(at: scriptURL)
        }

        logger.notice("Claude statusline hook uninstalled (restored original: \(backup != nil, privacy: .public))")
    }

    // MARK: - settings.json read/write (unknown-key-preserving)

    /// Reads `settings.json` into a raw dictionary, preserving every key.
    ///
    /// Returns an empty dictionary when the file is missing or empty; throws a
    /// `ProviderError(.decode)` when present but not a JSON object.
    private func readSettings() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsPath.path) else { return [:] }
        let data = try Data(contentsOf: settingsPath)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError(kind: .decode, message: "settings.json is not a JSON object")
        }
        return object
    }

    /// Serialises and atomically writes the settings dictionary.
    ///
    /// `.sortedKeys` gives stable output across writes; `.prettyPrinted` keeps the file
    /// human-diffable (`cat`-able for debugging, per project constraints).
    ///
    /// Symlink + mode preservation: `.atomic` rename-replaces the path it is given, which
    /// would detach a symlinked `settings.json` (dotfiles managers — stow/chezmoi) and reset
    /// its permissions. We therefore write to the symlink-resolved destination and re-apply
    /// the original file's `posixPermissions` afterwards.
    private func writeSettings(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
        let destination = settingsPath.resolvingSymlinksInPath()
        let priorPermissions = (try? fileManager.attributesOfItem(atPath: destination.path))?[.posixPermissions]
        try data.write(to: destination, options: .atomic)
        if let priorPermissions {
            try? fileManager.setAttributes([.posixPermissions: priorPermissions], ofItemAtPath: destination.path)
        }
    }

    /// Deletes all but the `keeping` newest `settings.json.aub-backup-<epoch>` siblings.
    /// Sort key is the embedded epoch suffix (numeric), not directory order. Best-effort.
    private func pruneOldBackups(keeping: Int) {
        let dir = settingsPath.deletingLastPathComponent()
        let prefix = settingsPath.lastPathComponent + ".aub-backup-"
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
        let backups: [(name: String, epoch: Int)] = names.compactMap { name in
            guard name.hasPrefix(prefix), let epoch = Int(name.dropFirst(prefix.count)) else { return nil }
            return (name, epoch)
        }
        for stale in backups.sorted(by: { $0.epoch > $1.epoch }).dropFirst(keeping) {
            try? fileManager.removeItem(at: dir.appendingPathComponent(stale.name, isDirectory: false))
        }
    }

    /// Reads the backed-up original statusline object, or nil if absent/malformed.
    private func readOriginalBackup() throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: originalStatuslineURL.path) else { return nil }
        let data = try Data(contentsOf: originalStatuslineURL)
        guard !data.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Script template

    private static func commandIsOurs(_ command: String?) -> Bool {
        command?.contains(scriptFileName) ?? false
    }

    /// Builds the POSIX-sh tee script.
    ///
    /// The original command (when present) is appended on its own line, verbatim, as the
    /// right-hand side of a pipe: `printf '%s' "$input" | <original>`. Because it is placed
    /// literally — not inside a shell-quoted variable — an original command containing
    /// single or double quotes remains valid shell (it is parsed exactly as the user
    /// authored it).
    static func scriptContents(sessionsPath: String, originalCommand: String?) -> String {
        var lines: [String] = [
            "#!/bin/sh",
            "# Agents Usage Bar — statusline tee. Captures Claude Code statusline JSON,",
            "# then chains to the original statusline. Managed by Agents Usage Bar —",
            "# do not edit by hand; reinstall from the app instead.",
            "FEED_DIR=\"\(sessionsPath)\"",
            "input=$(cat)",
            "sid=$(printf '%s' \"$input\" | sed -n 's/.*\"session_id\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' | head -1)",
            "if [ -n \"$sid\" ]; then",
            "  mkdir -p \"$FEED_DIR\"",
            "  tmp=\"$FEED_DIR/.$sid.tmp.$$\"",
            "  # Remove the temp file on ANY exit — a failed mv must not strand hidden files.",
            "  trap 'rm -f \"$tmp\"' EXIT",
            "  printf '%s' \"$input\" > \"$tmp\" && mv -f \"$tmp\" \"$FEED_DIR/$sid.json\"",
            "fi"
        ]

        if let originalCommand,
           !originalCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("# --- chained original statusline (embedded verbatim) ---")
            lines.append("printf '%s' \"$input\" | \(originalCommand)")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}

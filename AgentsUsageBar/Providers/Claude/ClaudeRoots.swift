import Foundation

/// Defines the default root directories scanned for Claude JSONL transcript files.
///
/// Claude Code transcripts live under `~/.claude/projects/**/*.jsonl`.
/// CCS (Claude Code Sessions wrapper) transcripts live under:
///   - `~/.ccs/shared/context-groups/<group>/projects/**/*.jsonl`
///   - `~/.ccs/instances/<instance>/projects/**/*.jsonl`
///
/// `ClaudeJSONLProvider` is initialised with `ClaudeRoots.defaultRoots` in production and
/// receives an injected `[tempDir]` in tests — no file-system access at init time except
/// here, where we enumerate the user's home directory once at boot.
public enum ClaudeRoots {

    /// Returns all transcript root URLs that currently exist on disk.
    ///
    /// Roots that do not exist are skipped — the scanner tolerates missing paths but
    /// returning a tighter list avoids redundant `FileManager` walks.
    public static var defaultRoots: [URL] {
        let home = NSHomeDirectory()
        var roots: [URL] = []
        let fm = FileManager.default

        let claudeProjects = URL(fileURLWithPath: home + "/.claude/projects", isDirectory: true)
        if fm.fileExists(atPath: claudeProjects.path) {
            roots.append(claudeProjects)
        }

        // CCS shared context-groups: ~/.ccs/shared/context-groups/<group>/projects/
        let sharedGroupsRoot = URL(fileURLWithPath: home + "/.ccs/shared/context-groups", isDirectory: true)
        roots.append(contentsOf: enumerateProjectsChildren(of: sharedGroupsRoot, fileManager: fm))

        // CCS per-instance: ~/.ccs/instances/<instance>/projects/
        let instancesRoot = URL(fileURLWithPath: home + "/.ccs/instances", isDirectory: true)
        roots.append(contentsOf: enumerateProjectsChildren(of: instancesRoot, fileManager: fm))

        return roots
    }

    /// Enumerates `<parent>/<child>/projects/` directories that exist on disk.
    /// Used to discover all CCS context-groups and instances at boot.
    private static func enumerateProjectsChildren(of parent: URL, fileManager fm: FileManager) -> [URL] {
        guard fm.fileExists(atPath: parent.path),
              let children = try? fm.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return []
        }
        return children.compactMap { child in
            let projects = child.appendingPathComponent("projects", isDirectory: true)
            return fm.fileExists(atPath: projects.path) ? projects : nil
        }
    }
}

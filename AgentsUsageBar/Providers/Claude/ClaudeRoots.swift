import Foundation

/// Defines the default root directories scanned for Claude JSONL transcript files.
///
/// CLAUDE-01: Claude Code writes transcripts under `~/.claude/projects/**/*.jsonl`.
/// `ClaudeJSONLProvider` is initialised with `ClaudeRoots.defaultRoots` in production and
/// receives an injected `[tempDir]` in tests — no file-system access at init time.
public enum ClaudeRoots {

    /// Default root URL array scanned by `ClaudeJSONLProvider.fetch(now:)`.
    ///
    /// Points to `~/.claude/projects/` — the canonical Claude Code project directory.
    /// Production `AppDependencies.makeProduction()` passes this as the `roots` parameter.
    /// Tests inject a fresh `FileManager.default.temporaryDirectory` sub-path instead.
    public static let defaultRoots: [URL] = [
        URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects", isDirectory: true)
    ]
}

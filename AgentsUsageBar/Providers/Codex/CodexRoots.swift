import Foundation

/// Defines the default root directory scanned for Codex rollout JSONL files.
///
/// Codex CLI writes one rollout file per session at:
///   `~/.codex/sessions/YYYY/MM/DD/rollout-<ISO8601>-<UUID>.jsonl`
///
/// Unlike Claude (which lives across both `~/.claude/` and CCS layouts), Codex
/// uses a single canonical root. Phase 03-01 introduces the override seam via
/// `CodexRolloutScanner.init(now:fileManager:root:)` so tests can inject a
/// temp-dir fixture root without altering production behaviour.
public enum CodexRoots {

    /// Returns `~/.codex/sessions` when it exists on disk, otherwise `nil`.
    ///
    /// The scanner treats `nil` as "no Codex data" and short-circuits to an
    /// empty result, matching the cold-launch UX from Phase 1 D-03 — the
    /// downstream `CodexJSONLProvider` (Plan 03-02) renders a muted
    /// "No data yet" row when this returns `nil` AND the OAuth fallback fails.
    public static var defaultRoot: URL? {
        let home = NSHomeDirectory()
        let url = URL(fileURLWithPath: home + "/.codex/sessions", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

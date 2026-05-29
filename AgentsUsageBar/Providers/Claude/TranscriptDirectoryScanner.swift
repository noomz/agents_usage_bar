import Foundation
import os

/// Walks one or more root directories and returns `.jsonl` files filtered by mtime.
///
/// Used by Plan 02.04 (ClaudeJSONLProvider) to find JSONL transcripts under
/// `~/.claude/projects/` that have been modified since the last poll, keeping
/// CPU cost low via `.contentModificationDateKey` filtering instead of whole-tree
/// byte reads.
///
/// Hidden files and package descendants are excluded via the enumerator options.
public struct TranscriptDirectoryScanner: Sendable {

    // MARK: - Properties

    // nonisolated(unsafe): FileManager is not Sendable in Swift 6; .default is a
    // thread-safe singleton per Apple docs. We only call read-only enumeration APIs.
    // Rule 1 fix: pre-existing Swift 6 strict concurrency diagnostic.
    nonisolated(unsafe) private let fileManager: FileManager
    private let logger = AppLogger.logger(category: "jsonl")

    // MARK: - Initializers

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Public API

    /// Returns absolute URLs of `*.jsonl` files found under `roots`, optionally
    /// filtered to only those modified after `since`.
    ///
    /// - Parameters:
    ///   - roots: Array of root directories to enumerate recursively.
    ///   - since: When non-nil, only files with `contentModificationDate > since` are returned.
    ///     Pass `nil` to return all `.jsonl` files regardless of mtime.
    /// - Returns: Flat array of absolute `URL` values — not sorted, order matches enumerator.
    ///
    /// Non-existent roots are logged and silently skipped; other roots still process.
    public func scanRoots(_ roots: [URL], modifiedSince since: Date?) -> [URL] {
        var results: [URL] = []

        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else {
                logger.notice(
                    "scan root missing: \(root.lastPathComponent, privacy: .public)"
                )
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                logger.warning(
                    "enumerator creation failed for root: \(root.lastPathComponent, privacy: .public)"
                )
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }

                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                )
                guard values?.isRegularFile == true else { continue }

                if let since, let mtime = values?.contentModificationDate, mtime <= since {
                    continue
                }

                // Resolve symlinks so the URL key is canonical.
                // On macOS, FileManager.enumerator returns URLs under /private/var/folders
                // while URL construction via temporaryDirectory + appendingPathComponent
                // returns /var/folders (which is a symlink). Normalizing here ensures
                // cache keys match regardless of which path form was used to construct
                // the root directory. Rule 1 fix: symlink mismatch causing nil offset lookup.
                results.append(url.resolvingSymlinksInPath())
            }
        }

        return results
    }
}

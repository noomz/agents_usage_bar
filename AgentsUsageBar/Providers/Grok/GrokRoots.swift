import Foundation

/// Default filesystem roots for the Grok Build TUI (`grok` CLI).
///
/// Matches the CLI: `$GROK_HOME` when set and non-empty, otherwise `~/.grok`.
public enum GrokRoots {

    /// Resolved Grok home directory.
    public static func home(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["GROK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appending(path: ".grok", directoryHint: .isDirectory)
    }

    public static func authJSON(home: URL) -> URL {
        home.appending(path: "auth.json")
    }

    public static func sessionsDirectory(home: URL) -> URL {
        home.appending(path: "sessions", directoryHint: .isDirectory)
    }
}

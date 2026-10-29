import Foundation

enum PiSessionRoots {
    /// `$PI_CODING_AGENT_DIR` if non-empty, else `~/.pi/agent`.
    static func agentDirectory(
        environment: [String: String],
        home: String = NSHomeDirectory()
    ) -> URL {
        if let override = environment["PI_CODING_AGENT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return defaultAgentDirectory(home: home)
    }

    /// Session trees to scan. If env dir ≠ default, scan both when they exist.
    static func sessionDirectories(
        environment: [String: String],
        home: String = NSHomeDirectory()
    ) -> [URL] {
        let defaultSessions = defaultAgentDirectory(home: home).appendingPathComponent("sessions", isDirectory: true)
        var urls = [defaultSessions]
        if let override = environment["PI_CODING_AGENT_DIR"], !override.isEmpty {
            urls.append(
                URL(fileURLWithPath: override, isDirectory: true)
                    .appendingPathComponent("sessions", isDirectory: true)
            )
        }
        return uniqueURLs(urls)
    }

    static func modelsJSONFiles(
        environment: [String: String],
        home: String = NSHomeDirectory()
    ) -> [URL] {
        let defaultModels = defaultAgentDirectory(home: home).appendingPathComponent("models.json")
        var urls = [defaultModels]
        if let override = environment["PI_CODING_AGENT_DIR"], !override.isEmpty {
            urls.append(
                URL(fileURLWithPath: override, isDirectory: true)
                    .appendingPathComponent("models.json")
            )
        }
        return uniqueURLs(urls)
    }

    private static func defaultAgentDirectory(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
    }

    /// Collapse `$PI_CODING_AGENT_DIR` when it is a symlink of `~/.pi/agent`.
    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var out: [URL] = []
        for url in urls {
            let resolved = url.resolvingSymlinksInPath()
            if seen.insert(resolved.standardizedFileURL.path).inserted {
                out.append(resolved)
            }
        }
        return out
    }
}

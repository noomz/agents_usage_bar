import Foundation

// MARK: - EnvReader Protocol

/// Protocol for reading environment variables.
///
/// CFG-06 anti-feature enforcement: implementations MUST only read from
/// `ProcessInfo.environment` — never from shell RC files, never by spawning a subprocess.
/// The only production conformer is `ProcessInfoEnvReader`. Test code uses `DictionaryEnvReader`.
public protocol EnvReader: Sendable {
    /// Returns the value of the given environment variable, or `nil` if absent or empty.
    func value(forKey key: String) -> String?
}

// MARK: - ProcessInfoEnvReader

/// Production `EnvReader` that reads from `ProcessInfo.processInfo.environment`.
///
/// Empty-string values are treated as absent (same as unset) so that
/// `OPENROUTER_API_KEY=` does not look like "set to empty string".
///
/// SEC-05 / CFG-06: This is the ONLY permitted source for environment variable reads.
/// DO NOT read `~/.zshrc`, `~/.bashrc`, `~/.config/fish/config.fish`, or any shell rc file.
public struct ProcessInfoEnvReader: EnvReader {
    public init() {}

    public func value(forKey key: String) -> String? {
        let v = ProcessInfo.processInfo.environment[key]
        return (v?.isEmpty == false) ? v : nil
    }
}

// MARK: - DictionaryEnvReader (test seam)

/// Test seam `EnvReader` backed by a plain dictionary.
///
/// Empty-string values are treated as absent (mirrors `ProcessInfoEnvReader` behaviour).
public struct DictionaryEnvReader: EnvReader {
    private let dict: [String: String]

    public init(_ dict: [String: String]) {
        self.dict = dict
    }

    public func value(forKey key: String) -> String? {
        let v = dict[key]
        return (v?.isEmpty == false) ? v : nil
    }
}

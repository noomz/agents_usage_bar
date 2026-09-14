import Foundation

/// Resolves a `LocalEngineConfig` to a single localhost port.
///
/// Process matching is **not** a port sweep (LOCAL-03): we only probe a port
/// taken from argv (`--port`) or from the engine's explicit `port` field.
public enum LocalEngineResolver {

    /// `--port 8123` / `--port=8123` in `llama-server` argv.
    public static func port(fromArguments args: [String]) -> Int? {
        for (index, arg) in args.enumerated() {
            if arg == "--port", index + 1 < args.count {
                return parsePort(args[index + 1])
            }
            if arg.hasPrefix("--port=") {
                return parsePort(String(arg.dropFirst("--port=".count)))
            }
        }
        return nil
    }

    /// First matching process port, else the engine's explicit port.
    /// Skips ports already owned by Ollama / LM Studio Express / `[llamacpp]`.
    public static func resolvePort(
        engine: LocalEngineConfig,
        processes: [RunningProcess],
        reservedPorts: Set<Int>
    ) -> Int? {
        if let match = engine.matchPath, !match.isEmpty {
            for process in processes where process.executablePath.contains(match) {
                if let port = port(fromArguments: process.arguments) ?? engine.port,
                   !reservedPorts.contains(port) {
                    return port
                }
            }
        }
        if let port = engine.port, !reservedPorts.contains(port) {
            return port
        }
        return nil
    }

    private static func parsePort(_ raw: String) -> Int? {
        guard let value = Int(raw), (1...65535).contains(value) else { return nil }
        return value
    }
}

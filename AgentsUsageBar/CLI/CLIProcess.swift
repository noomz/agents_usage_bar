import Foundation
import Darwin

/// Resolves a PATH symlink back into the `.app` bundle so `Bundle.main` and
/// `UserDefaults.standard` are the GUI's, not `/opt/homebrew/bin`.
public enum CLIProcess {
    /// When `argv0` is a symlink (or a bare `aub` found on PATH) pointing at
    /// `Something.app/Contents/MacOS/<exe>`, returns the real executable path.
    /// `nil` when already running the bundled binary.
    public static func bundledExecutable(
        argv0: String,
        pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let url = absoluteURL(argv0: argv0, pathEnvironment: pathEnvironment, fileExists: fileExists)
        let resolved = url.resolvingSymlinksInPath()
        if url.standardizedFileURL.path == resolved.standardizedFileURL.path {
            return nil
        }
        guard resolved.path.contains(".app/Contents/MacOS/") else { return nil }
        return resolved.path
    }

    private static func absoluteURL(
        argv0: String,
        pathEnvironment: String,
        fileExists: (String) -> Bool
    ) -> URL {
        if argv0.hasPrefix("/") {
            return URL(fileURLWithPath: argv0)
        }
        if argv0.contains("/") {
            return URL(fileURLWithPath: argv0).standardizedFileURL
        }
        for dir in pathEnvironment.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(argv0)
            if fileExists(candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return URL(fileURLWithPath: argv0)
    }

    /// Arguments to `execv` so a PATH `aub` invocation keeps CLI mode after re-exec.
    public static func reexecArguments(realExecutable: String, original: [String]) -> [String] {
        var rest = Array(original.dropFirst())
        if rest.first != "--cli" {
            rest.insert("--cli", at: 0)
        }
        return [realExecutable] + rest
    }

    /// Replaces this process with the bundled executable when launched via symlink.
    /// No-op when already inside the app bundle (Finder / `open`).
    public static func reexecIfInvokedViaSymlink() {
        var buf = [CChar](repeating: 0, count: 4096)
        var size = UInt32(buf.count)
        let invoked: String
        if _NSGetExecutablePath(&buf, &size) == 0 {
            invoked = String(cString: buf)
        } else {
            invoked = CommandLine.arguments[0]
        }
        guard let real = bundledExecutable(argv0: invoked) else { return }
        let argv = reexecArguments(realExecutable: real, original: CommandLine.arguments)
        let cArgs = argv.map { strdup($0) } + [nil]
        cArgs.withUnsafeBufferPointer { pointer in
            _ = execv(real, pointer.baseAddress)
        }
    }
}

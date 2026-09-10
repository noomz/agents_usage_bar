import Foundation

/// Filesystem seam for `CLIInstaller`. Production wraps `FileManager`; tests inject a fake.
public protocol CLIInstallerFileSystem: Sendable {
    var homeDirectory: String { get }
    var executablePath: String { get }
    var pathEnvironment: String { get }
    func directoryExists(atPath path: String) -> Bool
    func isWritableDirectory(atPath path: String) -> Bool
    func fileExists(atPath path: String) -> Bool
    func isSymlink(atPath path: String) -> Bool
    func destinationOfSymlink(atPath path: String) throws -> String
    func createDirectory(atPath path: String) throws
    func createSymlink(atPath path: String, destination: String) throws
    func removeItem(atPath path: String) throws
    func runPrivileged(script: String) throws
}

public struct FoundationCLIInstallerFileSystem: CLIInstallerFileSystem, Sendable {
    public init() {}

    public var homeDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    public var executablePath: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? CommandLine.arguments[0]
    }

    public var pathEnvironment: String {
        ProcessInfo.processInfo.environment["PATH"] ?? ""
    }

    public func directoryExists(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public func isWritableDirectory(atPath path: String) -> Bool {
        FileManager.default.isWritableFile(atPath: path)
    }

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func isSymlink(atPath path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let type = attrs?[.type] as? FileAttributeType else { return false }
        return type == .typeSymbolicLink
    }

    public func destinationOfSymlink(atPath path: String) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    public func createDirectory(atPath path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func createSymlink(atPath path: String, destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    public func removeItem(atPath path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    public func runPrivileged(script: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "do shell script \(Self.quoteAppleScript(script)) with administrator privileges"]
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw CLIInstaller.Error.authorizationCancelled
        }
    }

    private static func quoteAppleScript(_ shell: String) -> String {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// Preset destinations for the Settings picker and `aub install`.
///
/// Default is `~/.local/bin` (XDG user executables; pipx / uv / mise). That
/// directory is **not** on stock macOS PATH (`path_helper` only ships
/// `/usr/local/bin` in `/etc/paths`), so we show a PATH hint after install.
/// `/usr/local/bin` is on PATH but often needs admin; `/opt/homebrew/bin` is
/// on PATH only after Homebrew's `shellenv`.
public enum CLIInstallPreset: String, CaseIterable, Identifiable, Sendable, Equatable {
    case homeLocal
    case homebrew
    case usrLocal

    public var id: String { rawValue }

    public var menuLabel: String {
        switch self {
        case .homeLocal: return "~/.local/bin"
        case .homebrew:  return "/opt/homebrew/bin"
        case .usrLocal:  return "/usr/local/bin"
        }
    }

    public func directory(homeDirectory: String) -> String {
        switch self {
        case .homeLocal:
            return (homeDirectory as NSString).appendingPathComponent(".local/bin")
        case .homebrew:
            return "/opt/homebrew/bin"
        case .usrLocal:
            return "/usr/local/bin"
        }
    }

    public static func matching(path: String, homeDirectory: String) -> CLIInstallPreset? {
        allCases.first { $0.directory(homeDirectory: homeDirectory) == path }
    }
}

public enum CLIInstallStatus: Equatable, Sendable {
    case notInstalled
    case installed(path: String)
    case repairNeeded(path: String)

    public var buttonTitle: String {
        switch self {
        case .notInstalled: return "Install aub"
        case .installed: return "Uninstall"
        case .repairNeeded: return "Repair"
        }
    }

    public var caption: String {
        switch self {
        case .notInstalled:
            return "Symlink `aub` onto your PATH"
        case .installed(let path):
            return "Installed · \(path)"
        case .repairNeeded(let path):
            return "Broken symlink at \(path)"
        }
    }
}

public struct CLIInstaller: Sendable {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case notADirectory(String)
        case wouldClobberFile(String)
        case authorizationCancelled
        case noWritableDestination
        case coverageInstrumented
        case underlying(String)

        public var description: String {
            switch self {
            case .notADirectory(let p): return "not a directory: \(p)"
            case .wouldClobberFile(let p): return "refusing to clobber regular file: \(p)"
            case .authorizationCancelled: return "administrator authorization cancelled"
            case .noWritableDestination: return "no writable bin directory found"
            case .coverageInstrumented:
                return "this binary is a coverage-instrumented test/Debug build and would write default.profraw into the caller's working directory. Install from a Release build (scripts/build-local.sh or a GitHub Release)."
            case .underlying(let s): return s
            }
        }
    }

    public let fs: any CLIInstallerFileSystem
    public static let binaryName = "aub"

    public init(fs: any CLIInstallerFileSystem = FoundationCLIInstallerFileSystem()) {
        self.fs = fs
    }

    /// Known bin directories we may have written a symlink into.
    public func candidateDirectories() -> [String] {
        CLIInstallPreset.allCases.map { $0.directory(homeDirectory: fs.homeDirectory) }
    }

    public func defaultDirectory() -> String {
        CLIInstallPreset.homeLocal.directory(homeDirectory: fs.homeDirectory)
    }

    public func status(in directory: String) -> CLIInstallStatus {
        let exe = (fs.executablePath as NSString).standardizingPath
        let link = (directory as NSString).appendingPathComponent(Self.binaryName)
        guard fs.fileExists(atPath: link) || fs.isSymlink(atPath: link) else {
            return .notInstalled
        }
        guard fs.isSymlink(atPath: link),
              let dest = try? fs.destinationOfSymlink(atPath: link) else {
            return .repairNeeded(path: link)
        }
        let resolved = (dest as NSString).standardizingPath
        if resolved == exe || dest == fs.executablePath {
            return .installed(path: link)
        }
        return .repairNeeded(path: link)
    }

    public func status() -> CLIInstallStatus {
        var firstBroken: String?
        for dir in candidateDirectories() {
            switch status(in: dir) {
            case .installed(let path):
                return .installed(path: path)
            case .repairNeeded(let path):
                if firstBroken == nil { firstBroken = path }
            case .notInstalled:
                continue
            }
        }
        if let broken = firstBroken { return .repairNeeded(path: broken) }
        return .notInstalled
    }

    public func isOnPATH(_ directory: String) -> Bool {
        fs.pathEnvironment.split(separator: ":").contains { String($0) == directory }
    }

    /// Shell snippet when `directory` is missing from PATH. `nil` when already searchable.
    public func pathHint(for directory: String) -> String? {
        if isOnPATH(directory) { return nil }
        if directory == defaultDirectory() {
            return "Not on PATH. fish: fish_add_path ~/.local/bin   zsh/bash: export PATH=\"$HOME/.local/bin:$PATH\""
        }
        if directory == CLIInstallPreset.homebrew.directory(homeDirectory: fs.homeDirectory) {
            return "Not on PATH. Add Homebrew to your shell: eval \"$(/opt/homebrew/bin/brew shellenv)\""
        }
        return "Not on PATH. Add \(directory) to PATH in your shell profile."
    }

    @discardableResult
    public func install(prefix: String? = nil) throws -> String {
        let exe = fs.executablePath
        if CLIProcess.containsCoverageInstrumentation(atPath: exe) {
            throw Error.coverageInstrumented
        }
        let dir = prefix ?? defaultDirectory()
        try uninstall()
        if !fs.directoryExists(atPath: dir) {
            do {
                try fs.createDirectory(atPath: dir)
            } catch {
                try installPrivileged(directory: dir, destination: exe)
                return (dir as NSString).appendingPathComponent(Self.binaryName)
            }
        }
        if fs.isWritableDirectory(atPath: dir) {
            return try installLink(in: dir, destination: exe, createDir: false)
        }
        try installPrivileged(directory: dir, destination: exe)
        return (dir as NSString).appendingPathComponent(Self.binaryName)
    }

    public func uninstall() throws {
        let exe = (fs.executablePath as NSString).standardizingPath
        for dir in candidateDirectories() {
            let link = (dir as NSString).appendingPathComponent(Self.binaryName)
            guard fs.isSymlink(atPath: link),
                  let dest = try? fs.destinationOfSymlink(atPath: link) else { continue }
            let resolved = (dest as NSString).standardizingPath
            if resolved == exe || dest == fs.executablePath {
                try fs.removeItem(atPath: link)
            }
        }
    }

    private func installLink(in dir: String, destination: String, createDir: Bool) throws -> String {
        if createDir, !fs.directoryExists(atPath: dir) {
            try fs.createDirectory(atPath: dir)
        }
        guard fs.directoryExists(atPath: dir) else { throw Error.notADirectory(dir) }
        let link = (dir as NSString).appendingPathComponent(Self.binaryName)
        if fs.fileExists(atPath: link) || fs.isSymlink(atPath: link) {
            if fs.isSymlink(atPath: link) {
                try fs.removeItem(atPath: link)
            } else {
                throw Error.wouldClobberFile(link)
            }
        }
        try fs.createSymlink(atPath: link, destination: destination)
        return link
    }

    private func installPrivileged(directory: String, destination: String) throws {
        let link = (directory as NSString).appendingPathComponent(Self.binaryName)
        let script = [
            "set -eu",
            "/bin/mkdir -p \(shellEscape(directory))",
            "/bin/ln -sf \(shellEscape(destination)) \(shellEscape(link))",
        ].joined(separator: "\n")
        try fs.runPrivileged(script: script)
    }

    private func shellEscape(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

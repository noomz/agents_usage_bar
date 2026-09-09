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
        case underlying(String)

        public var description: String {
            switch self {
            case .notADirectory(let p): return "not a directory: \(p)"
            case .wouldClobberFile(let p): return "refusing to clobber regular file: \(p)"
            case .authorizationCancelled: return "administrator authorization cancelled"
            case .noWritableDestination: return "no writable bin directory found"
            case .underlying(let s): return s
            }
        }
    }

    public let fs: any CLIInstallerFileSystem
    public static let binaryName = "aub"

    public init(fs: any CLIInstallerFileSystem = FoundationCLIInstallerFileSystem()) {
        self.fs = fs
    }

    /// Candidate bin directories, first match wins for a no-sudo install.
    public func candidateDirectories() -> [String] {
        let homeLocal = (fs.homeDirectory as NSString).appendingPathComponent(".local/bin")
        return ["/opt/homebrew/bin", "/usr/local/bin", homeLocal]
    }

    public func status() -> CLIInstallStatus {
        let exe = (fs.executablePath as NSString).standardizingPath
        var firstBroken: String?
        for dir in candidateDirectories() {
            let link = (dir as NSString).appendingPathComponent(Self.binaryName)
            guard fs.fileExists(atPath: link) || fs.isSymlink(atPath: link) else { continue }
            guard fs.isSymlink(atPath: link),
                  let dest = try? fs.destinationOfSymlink(atPath: link) else {
                if firstBroken == nil { firstBroken = link }
                continue
            }
            let resolved = (dest as NSString).standardizingPath
            if resolved == exe || dest == fs.executablePath {
                return .installed(path: link)
            }
            if firstBroken == nil { firstBroken = link }
        }
        if let broken = firstBroken { return .repairNeeded(path: broken) }
        return .notInstalled
    }

    public func pathHint() -> String? {
        let dirs = candidateDirectories()
        let path = fs.pathEnvironment
        let chosen = dirs.first { dir in
            path.split(separator: ":").contains { String($0) == dir }
        }
        if chosen != nil { return nil }
        let homeLocal = (fs.homeDirectory as NSString).appendingPathComponent(".local/bin")
        return "Add \(homeLocal) to PATH, e.g. fish_add_path ~/.local/bin"
    }

    @discardableResult
    public func install(prefix: String? = nil) throws -> String {
        let exe = fs.executablePath
        if let prefix {
            return try installLink(in: prefix, destination: exe, createDir: true)
        }

        if let dir = firstWritableExistingDir() {
            return try installLink(in: dir, destination: exe, createDir: false)
        }

        let homeLocal = (fs.homeDirectory as NSString).appendingPathComponent(".local/bin")
        if !fs.directoryExists(atPath: homeLocal) {
            try fs.createDirectory(atPath: homeLocal)
        }
        if fs.isWritableDirectory(atPath: homeLocal) {
            return try installLink(in: homeLocal, destination: exe, createDir: false)
        }

        try installPrivileged(destination: exe)
        if case .installed(let path) = status() { return path }
        return "/usr/local/bin/\(Self.binaryName)"
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

    private func firstWritableExistingDir() -> String? {
        candidateDirectories().first { dir in
            fs.directoryExists(atPath: dir) && fs.isWritableDirectory(atPath: dir)
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

    private func installPrivileged(destination: String) throws {
        var lines: [String] = ["set -eu"]
        for dir in ["/usr/local/bin", "/opt/homebrew/bin"] where fs.directoryExists(atPath: dir) {
            lines.append("/bin/mkdir -p \(shellEscape(dir))")
            lines.append("/bin/ln -sf \(shellEscape(destination)) \(shellEscape((dir as NSString).appendingPathComponent(Self.binaryName)))")
        }
        guard lines.count > 1 else { throw Error.noWritableDestination }
        try fs.runPrivileged(script: lines.joined(separator: "\n"))
    }

    private func shellEscape(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

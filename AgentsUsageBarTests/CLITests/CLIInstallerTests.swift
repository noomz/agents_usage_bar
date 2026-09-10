import Foundation
import Testing
@testable import AgentsUsageBar

private final class FakeFS: CLIInstallerFileSystem, @unchecked Sendable {
    var homeDirectory = "/Users/test"
    var executablePath = "/Applications/AgentsUsageBar.app/Contents/MacOS/AgentsUsageBar"
    var pathEnvironment = "/usr/bin"
    var dirs: Set<String> = []
    var writable: Set<String> = []
    var files: [String: String] = [:] // path → symlink dest; "" means regular file
    var privilegedScripts: [String] = []
    var denyPrivileged = false

    func directoryExists(atPath path: String) -> Bool { dirs.contains(path) }
    func isWritableDirectory(atPath path: String) -> Bool { writable.contains(path) }
    func fileExists(atPath path: String) -> Bool { files[path] != nil }
    func isSymlink(atPath path: String) -> Bool {
        if let dest = files[path], !dest.isEmpty { return true }
        return false
    }
    func destinationOfSymlink(atPath path: String) throws -> String {
        guard let dest = files[path], !dest.isEmpty else { throw CLIInstaller.Error.underlying("not a symlink") }
        return dest
    }
    func createDirectory(atPath path: String) throws {
        dirs.insert(path)
        writable.insert(path)
    }
    func createSymlink(atPath path: String, destination: String) throws {
        files[path] = destination
    }
    func removeItem(atPath path: String) throws { files.removeValue(forKey: path) }
    func runPrivileged(script: String) throws {
        if denyPrivileged { throw CLIInstaller.Error.authorizationCancelled }
        privilegedScripts.append(script)
        files["/usr/local/bin/aub"] = executablePath
    }
}

@Suite("CLIInstaller")
struct CLIInstallerTests {

    @Test("default is ~/.local/bin even when Homebrew is writable")
    func defaultIsHomeLocal() throws {
        let fs = FakeFS()
        fs.dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        fs.writable = ["/opt/homebrew/bin", "/usr/local/bin"]
        let installer = CLIInstaller(fs: fs)
        let path = try installer.install()
        #expect(path == "/Users/test/.local/bin/aub")
        #expect(fs.files[path] == fs.executablePath)
        #expect(fs.files["/opt/homebrew/bin/aub"] == nil)
    }

    @Test("creates ~/.local/bin when missing")
    func createsHomeLocal() throws {
        let fs = FakeFS()
        let installer = CLIInstaller(fs: fs)
        let path = try installer.install()
        #expect(path == "/Users/test/.local/bin/aub")
        #expect(fs.dirs.contains("/Users/test/.local/bin"))
        #expect(fs.files[path] == fs.executablePath)
    }

    @Test("refuses to clobber a regular file")
    func refusesClobber() {
        let fs = FakeFS()
        fs.dirs = ["/Users/test/.local/bin"]
        fs.writable = ["/Users/test/.local/bin"]
        fs.files["/Users/test/.local/bin/aub"] = "" // regular file
        let installer = CLIInstaller(fs: fs)
        do {
            _ = try installer.install()
            Issue.record("expected wouldClobberFile")
        } catch CLIInstaller.Error.wouldClobberFile {
            // expected
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test("replaces our existing symlink")
    func replacesOwnSymlink() throws {
        let fs = FakeFS()
        fs.dirs = ["/Users/test/.local/bin"]
        fs.writable = ["/Users/test/.local/bin"]
        fs.files["/Users/test/.local/bin/aub"] = "/old/AgentsUsageBar"
        let installer = CLIInstaller(fs: fs)
        let path = try installer.install()
        #expect(fs.files[path] == fs.executablePath)
    }

    @Test("prefix selects Homebrew over the default")
    func prefixSelectsHomebrew() throws {
        let fs = FakeFS()
        fs.dirs = ["/opt/homebrew/bin"]
        fs.writable = ["/opt/homebrew/bin"]
        let installer = CLIInstaller(fs: fs)
        let path = try installer.install(prefix: "/opt/homebrew/bin")
        #expect(path == "/opt/homebrew/bin/aub")
    }

    @Test("uninstall removes only our symlink")
    func uninstallOursOnly() throws {
        let fs = FakeFS()
        fs.dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        fs.writable = ["/opt/homebrew/bin"]
        fs.files["/opt/homebrew/bin/aub"] = fs.executablePath
        fs.files["/usr/local/bin/aub"] = "/someone/else"
        let installer = CLIInstaller(fs: fs)
        try installer.uninstall()
        #expect(fs.files["/opt/homebrew/bin/aub"] == nil)
        #expect(fs.files["/usr/local/bin/aub"] == "/someone/else")
    }

    @Test("status(in:) is per destination")
    func statusInDirectory() {
        let fs = FakeFS()
        fs.dirs = ["/Users/test/.local/bin", "/opt/homebrew/bin"]
        fs.files["/Users/test/.local/bin/aub"] = fs.executablePath
        let installer = CLIInstaller(fs: fs)
        #expect(installer.status(in: "/Users/test/.local/bin") == .installed(path: "/Users/test/.local/bin/aub"))
        #expect(installer.status(in: "/opt/homebrew/bin") == .notInstalled)
    }

    @Test("status installed / not installed / repair")
    func statusCases() {
        let fs = FakeFS()
        fs.dirs = ["/opt/homebrew/bin"]
        let installer = CLIInstaller(fs: fs)
        #expect(installer.status() == .notInstalled)
        fs.files["/opt/homebrew/bin/aub"] = fs.executablePath
        #expect(installer.status() == .installed(path: "/opt/homebrew/bin/aub"))
        fs.files["/opt/homebrew/bin/aub"] = "/elsewhere"
        if case .repairNeeded = installer.status() {
            // ok
        } else {
            Issue.record("expected repairNeeded")
        }
    }

    @Test("button titles")
    func buttonTitles() {
        #expect(CLIInstallStatus.notInstalled.buttonTitle == "Install aub")
        #expect(CLIInstallStatus.installed(path: "/x").buttonTitle == "Uninstall")
        #expect(CLIInstallStatus.repairNeeded(path: "/x").buttonTitle == "Repair")
    }

    @Test("prefix install")
    func prefix() throws {
        let fs = FakeFS()
        let installer = CLIInstaller(fs: fs)
        let path = try installer.install(prefix: "/custom/bin")
        #expect(path == "/custom/bin/aub")
        #expect(fs.dirs.contains("/custom/bin"))
    }

    @Test("admin fallback records script for the selected prefix")
    func adminFallback() throws {
        let fs = FakeFS()
        fs.dirs = ["/usr/local/bin"]
        let installer = CLIInstaller(fs: fs)
        _ = try installer.install(prefix: "/usr/local/bin")
        #expect(!fs.privilegedScripts.isEmpty)
        #expect(fs.privilegedScripts[0].contains("/usr/local/bin"))
        #expect(fs.privilegedScripts[0].contains("ln -sf"))
    }

    @Test("pathHint for ~/.local/bin when missing from PATH")
    func pathHintHomeLocal() {
        let fs = FakeFS()
        fs.pathEnvironment = "/usr/bin:/bin"
        let installer = CLIInstaller(fs: fs)
        let hint = installer.pathHint(for: "/Users/test/.local/bin")
        #expect(hint != nil)
        #expect(hint?.contains("fish_add_path") == true)
        #expect(installer.pathHint(for: "/usr/bin") == nil)
    }

    @Test("install refuses a coverage-instrumented executable")
    func refusesInstrumentedBinary() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aub-install-prf-\(UUID().uuidString)")
        try Data("x__llvm_prf_namesx".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fs = FakeFS()
        fs.executablePath = tmp.path
        let installer = CLIInstaller(fs: fs)
        do {
            _ = try installer.install()
            Issue.record("expected coverageInstrumented")
        } catch CLIInstaller.Error.coverageInstrumented {
            // expected
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(fs.files["/Users/test/.local/bin/aub"] == nil)
    }

    @Test("preset matching")
    func presetMatching() {
        #expect(CLIInstallPreset.homeLocal.directory(homeDirectory: "/Users/test") == "/Users/test/.local/bin")
        #expect(CLIInstallPreset.matching(path: "/opt/homebrew/bin", homeDirectory: "/Users/test") == .homebrew)
        #expect(CLIInstallPreset.matching(path: "/usr/local/bin", homeDirectory: "/Users/test") == .usrLocal)
    }
}

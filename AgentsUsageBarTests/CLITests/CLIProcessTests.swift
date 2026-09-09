import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("CLIProcess")
struct CLIProcessTests {
    @Test("symlink into .app Contents/MacOS is the bundled executable")
    func bundledExecutableFromSymlink() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aub-cli-process-\(UUID().uuidString)")
        let macOS = tmp.appendingPathComponent("AgentsUsageBar.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let real = macOS.appendingPathComponent("AgentsUsageBar")
        try Data("x".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(
            at: tmp.appendingPathComponent("aub"),
            withDestinationURL: real
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let found = CLIProcess.bundledExecutable(argv0: tmp.appendingPathComponent("aub").path)
        #expect(found == real.path)
    }

    @Test("real path inside the bundle does not re-exec")
    func alreadyBundled() {
        let path = "/Applications/AgentsUsageBar.app/Contents/MacOS/AgentsUsageBar"
        #expect(CLIProcess.bundledExecutable(argv0: path) == nil)
    }

    @Test("bare `aub` on PATH resolves through the symlink")
    func bareNameOnPATH() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aub-cli-path-\(UUID().uuidString)")
        let macOS = tmp.appendingPathComponent("AgentsUsageBar.app/Contents/MacOS")
        let bin = tmp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let real = macOS.appendingPathComponent("AgentsUsageBar")
        try Data("x".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("aub"),
            withDestinationURL: real
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let found = CLIProcess.bundledExecutable(
            argv0: "aub",
            pathEnvironment: bin.path
        )
        #expect(found == real.path)
    }

    @Test("re-exec injects --cli so a bare `aub` stays in CLI mode")
    func reexecInjectsCLI() {
        let real = "/App.app/Contents/MacOS/AgentsUsageBar"
        let args = CLIProcess.reexecArguments(realExecutable: real, original: ["/opt/homebrew/bin/aub"])
        #expect(args == [real, "--cli"])
        let withSub = CLIProcess.reexecArguments(
            realExecutable: real,
            original: ["/opt/homebrew/bin/aub", "usage", "--json"]
        )
        #expect(withSub == [real, "--cli", "usage", "--json"])
    }
}

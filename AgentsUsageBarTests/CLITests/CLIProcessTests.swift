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

    @Test("coverage scanner finds __llvm_prf and ignores a clean file")
    func coverageScanner() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aub-prf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dirty = tmp.appendingPathComponent("dirty.bin")
        let clean = tmp.appendingPathComponent("clean.bin")
        try Data("header\0__llvm_prf_cnts\0tail".utf8).write(to: dirty)
        try Data("plain mach-o placeholder".utf8).write(to: clean)

        #expect(CLIProcess.coverageNeedle == Data("__llvm_prf".utf8))
        #expect(CLIProcess.containsCoverageInstrumentation(atPath: dirty.path))
        #expect(!CLIProcess.containsCoverageInstrumentation(atPath: clean.path))
        #expect(!CLIProcess.containsCoverageInstrumentation(atPath: tmp.appendingPathComponent("missing").path))
    }

    @Test("check-no-coverage.sh rejects __llvm_prf and accepts a clean file")
    func checkNoCoverageScript() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aub-prf-sh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dirty = tmp.appendingPathComponent("dirty.bin")
        let clean = tmp.appendingPathComponent("clean.bin")
        try Data("header__llvm_prf_datatail".utf8).write(to: dirty)
        try Data("no instrumentation here".utf8).write(to: clean)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("scripts/check-no-coverage.sh")

        func run(_ file: URL) throws -> Int32 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [script.path, file.path]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        }

        #expect(try run(dirty) == 1)
        #expect(try run(clean) == 0)
    }
}
